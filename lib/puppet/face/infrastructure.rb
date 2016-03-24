require 'puppet/face'
require 'puppet/node/facts'
require 'puppet/network/http_pool'

begin
  require 'mcollective'
  include MCollective::RPC
rescue LoadError
  Puppet.warning 'MCollective functionality unavailable.'
end

begin
  require 'net/ssh'
rescue LoadError
  Puppet.warning 'SSH functionality unavailable.'
end

Puppet::Face.define(:infrastructure, '0.0.1') do
  copyright "Ben Ford", 2016
  license   "Apache 2 license; see COPYING"
  summary "Display or deploy a Puppet application infrastructure."

  description <<-'EOT'
    This subcommand uses the language features of Application Orchestration to
    deploy a full infrastructure as described by an environment. It will determine
    dependencies and a run order, then run nodes concurrently to meet requirements,
    skipping any nodes with failed dependencies. It can use either MCollective or
    SSH to orchestrate Puppet runs.
  EOT

  examples <<-'EOT'
    $ puppet infrastructure describe
    $ puppet infrastructure describe --environment staging
    $ puppet infrastructure deploy
    $ puppet infrastructure deploy --transport mco
    $ puppet infrastructure deploy --transport ssh --map hostnames.yaml --key ~/.ssh/deploy.pem
  EOT

  action(:describe) do
    summary "Describe the infrastructure and deployment plan."
    returns "A list of all configured applications and an ordered node runlist."
    default

    when_invoked do |options|
      catalog = get_catalog()

      if catalog['applications'].empty?
        Puppet.warning 'Empty environment catalog'
        next
      end

      puts
      puts 'Applications:'
      catalog['applications'].each do |app, components|
        puts "  #{app}:"
        printf("    %20s %30s\n", 'Component', 'Node')
        puts '-------------------------------------------------------'
        components.each do |component, data|
          printf("    %20s %30s\n", component, data['node'])
        end
      end
      puts

      puts 'Runlist: '
      walk(catalog)

      nil
    end
  end

  action(:deploy) do
    summary "Deploy an infrastructure."
    returns "The infrastructure run report."

    option "-t TRANSPORT", "--transport TRANSPORT" do
      summary "Which transport backend (ssh/mco) to use. Defaults to 'mco'."
    end

    option "-m MAPPING", "--map MAPPING" do
      summary "Pathname to the mapping from certnames to hostnames in YAML format. Only used for the SSH transport."
    end

    option "-k SSHKEY", "--key SSHKEY" do
      summary "Which key to use for the SSH transport."
    end

    when_invoked do |options|
      catalog = get_catalog()

      case options[:transport]
      when 'ssh'
        map = (options.include? :map) ? YAML.load_file(File.expand_path(options[:map])) : {}
        key = (options.include? :key) ? File.expand_path(options[:key]) : nil

        walk(catalog) do |node|
          address = map[node] || node
          transport_ssh(address, 'root', key)
        end

      else
        walk(catalog) do |node|
          transport_mco(node)
        end
      end
    end
  end

  def get_catalog(environment = 'production')
    endpoint   = "/puppet/v3/environment/#{environment}"
    connection = Puppet::Network::HttpPool.http_instance(Puppet.settings[:server], Puppet.settings[:masterport])

    unless catalog = PSON.load(connection.request_get(endpoint, {"Accept" => 'application/json'}).body)
      raise "Error retrieving environment catalog for #{environment}."
    end

    #JSON.parse(File.read('example.json'))
    catalog
  end

  def mark_completed(nodes, completed)
    nodes.each do |node, waiting|
      waiting[:consumes] -= completed[:produces]
    end
  end

  # SSH to a node and run a command. Return
  def transport_ssh(node, user, key)
    return true
    exitcode = nil
    Net::SSH.start(node, user, :keys => [key]) do |ssh|
      ssh.open_channel do |chan|
        chan.on_request('exit-status') { |ch, data| exitcode = data.read_long }
        chan.exec('puppet agent -t')
      end
    end

    exitcode == 0
  end

  def transport_mco(node)
    mc = rpcclient('puppet')
    mc.discover(:nodes => [node])

    transport_mco_wait(mc, 120)
    mc.runonce()
    # we can rely on timestamps being within a few seconds of one another or mco wouldn't work anyway
    start = Time.now.to_i
    sleep 5
    transport_mco_wait(mc, 600)

    exitcode = 0
    mc.last_run_summary() do |resp|
      # we should only have a single response, but just in case, lets add
      # a successful run has zero failed resources.
      exitcode += resp[:body][:data][:failed_resources]
      # if the timestamp is greater than the time we kicked off the run, then ours failed
      # in a way that didn't generate a report properly
      exitcode += 1 if start > resp[:body][:data][:lastrun]
    end

    exitcode == 0
  end

  def transport_mco_wait(mc, timeout, delay=5)
    time = 0
    done = false
    while not done do
      mc.status() { |resp| done = ! resp[:body][:data][:applying] }

      unless done
        time += delay
        raise 'Timed out waiting for Puppet run to finish' if time > timeout

        sleep delay
      end
    end
  end

  # walk through the catalog using a modified mark & sweep algorithm.
  #
  # First run Puppet on all nodes which are not waiting for any service
  #   resources to be produced.
  # As each node completes, remove the service resources it produces from
  #   other nodes waiting to run.
  # Loop until either all nodes are complete, or there are no more nodes in
  #   the runlist which can satisfy requirements of waiting nodes.
  #
  def walk(catalog)
    nodes   = {}
    runlist = {}
    failed  = {}
    threads = {}

    catalog['applications'].each do |app, components|
      components.each do |component, data|
        nodename = data['node']
        nodes[nodename] ||= { :produces => [], :consumes => [] }
        nodes[nodename][:produces] += data['produces']
        nodes[nodename][:consumes] += data['consumes']
      end
    end

    loop do
      # move any nodes ready to go (not waiting for something to be produced) to the runlist
      runlist.merge! nodes.select { |node, rel| rel[:consumes].empty? }
      nodes.reject! { |node, rel| rel[:consumes].empty? }

      # if the runlist is empty, then that means that none are running and none are ready to run
      break if runlist.empty?

      runlist.each do |node, running|
        next if threads.include? node

        if block_given?
          puts "Enforcing configuration on #{node}..."
          # run the block passed in with the name of the node
          thr = Thread.new { yield(node, running) }
          threads.merge!( node => thr )
        else
          puts " * #{node} producing #{running[:produces].inspect}"
          mark_completed(nodes, running)
          runlist.delete(node)
        end
      end

      threads.each do |node, thr|
        next if thr.alive?

        if thr.value
          mark_completed(nodes, runlist[node])
        else
          failed.merge!(node => runlist[node])
        end

        threads.delete(node)
        runlist.delete(node)
      end

      sleep 5 if block_given?
    end

    puts "\nNode failues:" unless failed.empty?
    failed.each do |node, relationships|
      puts " * #{node}: "
      puts "    produces: #{relationships[:produces].inspect}"
    end

    puts "\nSkipped due to failed requirements:" unless nodes.empty?
    nodes.each do |node, relationships|
      puts " * #{node}: "
      puts "    consumes: #{relationships[:consumes].inspect}"
    end
    puts

  end
end