require File.expand_path(File.dirname(__FILE__) + '/base')

module KnifeJoyent
  class JoyentServerCreate < Chef::Knife

    include KnifeJoyent::Base

    deps do
      require 'fog'
      require 'readline'
      require 'chef/json_compat'
      require 'chef/knife/bootstrap'
      require 'ipaddr'
      Chef::Knife::Bootstrap.load_deps
    end
    
    banner 'knife joyent server create (options)'

    # mixlib option parsing
    option :name,
      :long => '--name <name>',
      :description => 'name for this machine'

    option :package,
      :short => '-f FLAVOR_NAME',
      :long => '--flavor FLAVOR_NAME',
      :description => 'specify flavor/package for the server'

    option :dataset,
      :short => '-I IMAGE_ID',
      :long => '--image IMAGE_ID',
      :description => 'specify image for the server'

    option :run_list,
      :short => "-r RUN_LIST",
      :long => "--run-list RUN_LIST",
      :description => "Comma separated list of roles/recipes to apply",
      :proc => lambda { |o| o.split(/[\s,]+/) },
      :default => []

    option :ssh_user,
      :short => "-x USERNAME",
      :long => "--ssh-user USERNAME",
      :description => "The ssh username",
      :default => "root"

    option :identity_file,
      :short => "-i IDENTITY_FILE",
      :long => "--identity-file IDENTITY_FILE",
      :description => "The SSH identity file used for authentication"

    option :chef_node_name,
      :short => "-N NAME",
      :long => "--node-name NAME",
      :description => "The Chef node name for your new node"

    option :prerelease,
      :long => "--prerelease",
      :description => "Install the pre-release chef gems"

    option :distro,
      :short => "-d DISTRO",
      :long => "--distro DISTRO",
      :description => "Bootstrap a distro using a template",
      :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d },
      :default => "chef-full"
      
    option :do_not_host_key_verify,
      :long => "--do-not-host-key-verify",
      :description => "Disable host key verification",
      :boolean => true,
      :default => false

    option :do_not_bootstrap,
      :long => "--do-not-bootstrap",
      :description => "Don't attempt to bootstrap the new node, stop after creation",
      :boolean => true,
      :default => false

    def is_linklocal(ip)
      linklocal = IPAddr.new "169.254.0.0/16"
      return linklocal.include?(ip)
    end
    
    def is_loopback(ip)
      loopback = IPAddr.new "127.0.0.0/8"
      return loopback.include?(ip)
    end
    
    def is_private(ip)
      block_a = IPAddr.new "10.0.0.0/8"
      block_b = IPAddr.new "172.16.0.0/12"
      block_c = IPAddr.new "192.168.0.0/16"
      return (block_a.include?(ip) or block_b.include?(ip) or block_c.include?(ip))
    end

    # wait for ssh to come up
    def tcp_test_ssh(hostname)
      tcp_socket = TCPSocket.new(hostname, 22)
      readable = IO.select([tcp_socket], nil, nil, 5)
      if readable
        Chef::Log.debug("sshd accepting connections on #{hostname}, banner is #{tcp_socket.gets}")
        yield
        true
      else
        false
      end
    rescue Errno::ETIMEDOUT
      false
    rescue Errno::EPERM
      false
    rescue Errno::ECONNREFUSED
      sleep 2
      false
    rescue Errno::EHOSTUNREACH
      sleep 2
      false
    ensure
      tcp_socket && tcp_socket.close
    end


    # Run Chef bootstrap script
    def bootstrap_for_node(server, pubip)
      bootstrap = Chef::Knife::Bootstrap.new
      Chef::Log.debug("Bootstrap name_args = [ #{server.ips.first} ]")
      bootstrap.name_args = [ pubip ]
      Chef::Log.debug("Bootstrap run_list = #{config[:run_list]}")
      bootstrap.config[:run_list] = config[:run_list]
      Chef::Log.debug("Bootstrap ssh_user = #{config[:ssh_user]}")
      bootstrap.config[:ssh_user] = config[:ssh_user]
      Chef::Log.debug("Bootstrap identity_file = #{config[:identity_file]}")
      bootstrap.config[:identity_file] = config[:identity_file]
      Chef::Log.debug("Bootstrap chef_node_name = #{config[:chef_node_name]}")
      bootstrap.config[:chef_node_name] = config[:chef_node_name] || server.id
      Chef::Log.debug("Bootstrap prerelease = #{config[:prerelease]}")
      bootstrap.config[:prerelease] = config[:prerelease]
      Chef::Log.debug("Bootstrap distro = #{config[:distro]}")
      bootstrap.config[:distro] = config[:distro]
      #Chef::Log.debug("Bootstrap use_sudo = #{config[:use_sudo]}")
      #bootstrap.config[:use_sudo] = true
      Chef::Log.debug("Bootstrap environment = #{config[:environment]}")
      bootstrap.config[:environment] = config[:environment]
      Chef::Log.debug("Bootstrap no_host_key_verify = #{config[:no_host_key_verify]}")
      bootstrap.config[:no_host_key_verify] = config[:do_not_host_key_verify]

      bootstrap
    end

    # Go
    def run
      puts ui.color("Creating machine #{config[:chef_node_name]}", :cyan)
      begin
        server = self.connection.servers.create(:dataset => config[:dataset],
                                            :package => config[:package],
                                            :name => config[:name])
      server.wait_for { print "."; ready? }                                      
      rescue => e
        Chef::Log.debug("e: #{e}")
        if e.response && e.response.body.kind_of?(String)
          error = MultiJson.decode(e.response.body)
          puts ui.error(error['message'])
          exit 1
        else
          raise
        end
      end

      puts ui.color("Created machine:", :cyan)
      msg("ID", server.id.to_s)
      msg("Name", server.name)
      msg("State", server.state)
      msg("Type", server.type)
      msg("Dataset", server.dataset)
      msg("IP's", server.ips)

      if config[:do_not_bootstrap]
        puts ui.color("Not bootstrapping this node, you'll have to run a separate bootstrap cycle with a run_list yourself")
      else
        pubip = server.ips.find{|ip| ip and not (is_loopback(ip) or is_private(ip) or is_linklocal(ip))}
        puts ui.color("Attempting to bootstrap on #{pubip}", :cyan)
        puts ui.color("NOTE: Bootstrapping doesn't currently work on SmartOS. Use https://github.com/joyent/smartmachine_cookbooks on a SmartOS node after creation", :cyan)

        print(".") until tcp_test_ssh(pubip) {
          sleep 1
          puts("done")
        }
        bootstrap_for_node(server, pubip).run
      end

      exit 0
    end
    
    def msg(label, value = nil)
      if value && !value.empty?
        puts "#{ui.color(label, :cyan)}: #{value}"
      end
    end
  end
end
