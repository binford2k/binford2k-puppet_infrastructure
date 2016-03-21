# puppet_infrastructure
Barebones implementation of an Application Orchestrator for open source Puppet
with an emphasis on the *barebones* part.

## Description

This subcommand uses the language features of Application Orchestration to
deploy a full infrastructure as described by an environment. It will determine
dependencies and a run order, then run nodes concurrently to meet requirements,
skipping any nodes with failed dependencies. It can use either MCollective or
SSH to orchestrate Puppet runs.

This is very *very* early in development, so it most likely won't work for you.
I highly suggest not even trying it out yet.

You can read about the language features at https://docs.puppetlabs.com/pe/latest/app_orchestration_workflow.html

### Example usage:

    $ puppet infrastructure describe
    $ puppet infrastructure describe --environment staging
    $ puppet infrastructure deploy
    $ puppet infrastructure deploy --transport mco
    $ puppet infrastructure deploy --transport ssh --map hostnames.yaml --key ~/.ssh/deploy.pem

### Displaying an infrastructure deployment plan:

    $ puppet infrastructure
    
    Applications:
      Webapp[pao]:
                   Component                           Node
    -------------------------------------------------------
                  Db[pao_db]                         agent1
                 Web[pao_w1]                         agent2
                 Web[pao_w2]                         agent3
                 Web[pao_w3]                         agent4
                  Lb[pao_lb]                         agent5
    
    Runlist:
     * agent1 producing ["Sql[pao_db]"]
     * agent2 producing ["Http[pao_w1]"]
     * agent3 producing ["Http[pao_w2]"]
     * agent4 producing ["Http[pao_w3]"]
     * agent5 producing []
 
### Deploying an infrastructure:

    $ puppet infrastructure deploy --transport ssh --map hostnames.yaml --key ~/.ssh/deploy.pem
    Enforcing configuration on agent1...
    Enforcing configuration on agent2...
    Enforcing configuration on agent3...
    Enforcing configuration on agent4...
    Enforcing configuration on agent5...

### Deploying an infrastructure with failures:

    $ puppet infrastructure deploy --transport ssh --map hostnames.yaml --key ~/.ssh/deploy.pem
    Enforcing configuration on agent1...
    Enforcing configuration on agent2...
    Enforcing configuration on agent3...
    Enforcing configuration on agent4...
    
    Node failues:
     * agent2:
        produces: ["Http[pao_w1]"]
    
    Skipped due to failed requirements:
     * agent5:
        consumes: ["Http[pao_w1]"]

### Runtime options:

* `ssh` transport:
  * `key`
    * An SSH key valid for the root user on each machine in your infrastructure.
  * `map`
    * A `.yaml` file mapping certnames to hostnames. Only required for nodes for
      which those are not equal.
* `mco` transport:
  * No configuration available.
  * Should support any platform the agent runs on.

#### Example hostname mapping file:

``` Yaml
---
agent1: foo.puppetlabs.vm
agent2: bar.puppetlabs.vm
agent3: baz.puppetlabs.vm
agent4: buz.puppetlabs.vm
```

### Auth configuration:

This requires that the node it's run on have access to the `environment` endpoint.
This might look something like the following:

    # /etc/puppetlabs/puppetserver/conf.d/auth.conf
    # ...
    {
        "allow" : ["master.puppetlabs.vm"],
        "match-request" : {
            "method" : "get",
            "path" : "/puppet/v3/environment",
            "query-params" : {},
            "type" : "path"
        },
        "name" : "puppetlabs environment",
        "sort-order" : 510
    }

This can be configured with the `puppetlabs/puppet_authorization` module

``` Puppet
puppet_authorization::rule { 'puppetlabs environment':
  match_request_path   => '/puppet/v3/environment',
  match_request_type   => 'path',
  match_request_method => 'get',
  allow                => ['master.puppetlabs.vm'],
  sort_order           => 510,
}
```

## Disclaimer

I take no liability for the use of this module.

Contact
-------

binford2k@gmail.com