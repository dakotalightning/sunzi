require 'open3'
require 'ostruct'
require 'net/ssh'

module Niso
  class Cli < Thor
    include Thor::Actions

    desc 'create', 'Create niso project'
    def create(project = 'niso')
      do_create(project)
    end

    desc 'deploy [user@host:port] [role] [--sudo] or deploy do [name] [role]  [--sudo]', 'Deploy niso project'
    method_options :sudo => false
    def deploy(first, *args)
      do_deploy(first, *args)
    end

    desc 'compile', 'Compile niso project'
    def compile(role = nil)
      do_compile(role)
    end

    desc 'setup', 'Setup a new VM'
    def setup(provider = "do")
      Niso::Cloud.new(self, provider).setup
    end

    desc 'teardown', 'Teardown an existing VM'
    def teardown(provider = "do")
      Niso::Cloud.new(self, provider).teardown
    end

    desc 'version', 'Show version'
    def version
      puts Gem.loaded_specs['niso'].version.to_s
    end

    no_tasks do
      Niso::Dependency.load('highline')
      include Niso::Utility

      def self.source_root
        File.expand_path('../../',__FILE__)
      end

      def do_create(project)
        copy_file 'templates/create/.gitignore',         "#{project}/.gitignore"
        copy_file 'templates/create/niso.yml',          "#{project}/niso.yml"
        copy_file 'templates/create/install.sh',         "#{project}/install.sh"
        copy_file 'templates/create/recipes/niso.sh',   "#{project}/recipes/niso.sh"
        copy_file 'templates/create/roles/db.sh',        "#{project}/roles/db.sh"
        copy_file 'templates/create/roles/web.sh',       "#{project}/roles/web.sh"
        copy_file 'templates/create/files/.gitkeep',     "#{project}/files/.gitkeep"
      end

      def do_deploy(first, *args)
        @ui = HighLine.new

        if ['do'].include?(first)
          @instance_attributes = YAML.load(File.read("#{first}/instances/#{args[0]}.yml"))
          target = @instance_attributes[:networks]["v4"].first["ip_address"]
          role = args[1]
        else
          target = first
          role = args[0]
        end

        sudo = 'sudo ' if options.sudo?
        user, host, port = parse_target(target)
        endpoint = "#{user}@#{host}"

        say "#{@ui.color("doing deploy", :green, :bold)}"
        say " #{@ui.color("user", :green, :bold)}  #{user}"
        say " #{@ui.color("host", :green, :bold)}  #{host}"
        say " #{@ui.color("port", :green, :bold)}  #{port}"
        say " #{@ui.color("role", :green, :bold)}  #{role}"

        begin
          # compile attributes and recipes
          do_compile(role)
        rescue Exception => e
          abort_with "#{e.message}"
        end

        begin
          # The host key might change when we instantiate a new VM, so
          # we remove (-R) the old host key from known_hosts.
          `ssh-keygen -R #{host} 2> /dev/null`

          remote_commands = <<-EOS
          rm -rf ~/niso &&
          mkdir ~/niso &&
          cd ~/niso &&
          tar xz &&
          #{sudo}bash install.sh
          EOS

          remote_commands.strip! << ' && rm -rf ~/niso' if @config['preferences'] and @config['preferences']['erase_remote_folder']

          local_commands = <<-EOS
          cd compiled
          tar cz . | ssh -o 'StrictHostKeyChecking no' #{endpoint} -p #{port} '#{remote_commands}'
          EOS

          Open3.popen3(local_commands) do |stdin, stdout, stderr|
            stdin.close
            t = Thread.new do
              while (line = stderr.gets)
                print line.color(:red)
              end
            end
            while (line = stdout.gets)
              print line.color(:green)
            end
            t.join
          end
        rescue Exception => e
          abort_with e.message
        end
      end

      def do_compile(role)
        # Check if you're in the niso directory
        abort_with 'You must be in the niso folder' unless File.exists?('niso.yml')
        # Check if role exists
        abort_with "#{role} doesn't exist!" if role and !File.exists?("roles/#{role}.sh")

        # Load niso.yml
        @config = YAML.load(File.read('niso.yml'))

        # Merge instance attributes
        @config['attributes'] ||= {}
        # @config['attributes'].update(Hash[@instance_attributes.map{|k,v| [k.to_s, v] }]) if @instance_attributes

        # Break down attributes into individual files
        (@config['attributes'] || {}).each {|key, value| create_file "compiled/attributes/#{key}", value }

        # Retrieve remote recipes via HTTP
        begin
          # compile attributes and recipes
          cache_remote_recipes = @config['preferences'] && @config['preferences']['cache_remote_recipes']
          (@config['recipes'] || []).each do |key, value|
            next if cache_remote_recipes and File.exists?("compiled/recipes/#{key}.sh")
            get value, "compiled/recipes/#{key}.sh"
          end
        rescue Exception => e
          abort_with "check your remote recipes in (niso.yml)\n#{e.message}"
        end

        copy_or_template = (@config['preferences'] && @config['preferences']['eval_erb']) ? :template : :copy_file
        copy_local_files(@config, copy_or_template)

        # Build install.sh
        if role
          if copy_or_template == :template
            template File.expand_path('install.sh'), 'compiled/_install.sh'
            create_file 'compiled/install.sh', File.binread('compiled/_install.sh') << "\n" << File.binread("compiled/roles/#{role}.sh")
          else
            create_file 'compiled/install.sh', File.binread('install.sh') << "\n" << File.binread("roles/#{role}.sh")
          end
        else
          send copy_or_template, File.expand_path('install.sh'), 'compiled/install.sh'
        end
      end

      def parse_target(target)
        target.match(/(.*@)?(.*?)(:.*)?$/)
        # Load ssh config if it exists
        config = Net::SSH::Config.for($2)
        [ ($1 && $1.delete('@') || config[:user] || 'root'),
          config[:host_name] || $2,
          ($3 && $3.delete(':') || config[:port] && config[:port].to_s || '22') ]
      end

      def copy_local_files(config, copy_or_template)
        @attributes = OpenStruct.new(config['attributes'])
        files = Dir['{recipes,roles,files}/**/*'].select { |file| File.file?(file) }
        files.each { |file| send copy_or_template, File.expand_path(file), File.expand_path("compiled/#{file}") }

        (config['files'] || []).each {|file| send copy_or_template, File.expand_path(file), "compiled/files/#{File.basename(file)}" }
      end
    end
  end
end
