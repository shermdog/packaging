namespace :pl do
  ##
  # This crazy piece of work establishes a remote repo on the distribution
  # server, ships our repos out to it, signs them, and brings them back.
  # This is an INTERNAL rake task and should not be considered part of the packaging API.
  # Please do not depend on it.
  #
  namespace :jenkins do
    ##
    # This is to enable the work in CPR-52 to support nightly repos. For this
    # work we'll have signed repos for each package of a build.
    #
    task :remote_sign_repos, [:target_prefix] => "pl:fetch" do |t, args|
      target_prefix = args.target_prefix or fail ":target_prefix is a required argument for #{t}"
      target = "#{target_prefix}_repos/"
      signing_server = Pkg::Config.signing_server
      # Sign the repos please
      Pkg::Util::File.empty_dir?("repos") and fail "There were no repos found in repos/. Maybe something in the pipeline failed?"
      signing_bundle = ENV['SIGNING_BUNDLE']

      remote_repo   = remote_bootstrap(signing_server, 'HEAD', nil, signing_bundle)
      build_params  = remote_buildparams(signing_server, Pkg::Config)
      Pkg::Util::Net.rsync_to('repos', signing_server, remote_repo)
      Pkg::Util::Net.remote_ssh_cmd(signing_server, "cd #{remote_repo} ; rake pl:jenkins:sign_repos GPG_KEY=#{Pkg::Config.gpg_key} PARAMS_FILE=#{build_params}")
      Pkg::Util::Net.rsync_from("#{remote_repo}/repos/", signing_server, target)
      Pkg::Util::Net.remote_ssh_cmd(signing_server, "rm -rf #{remote_repo}")
      Pkg::Util::Net.remote_ssh_cmd(signing_server, "rm #{build_params}")
      puts "Signed packages staged in '#{target}' directory"
    end

    task :sign_repos => "pl:fetch" do
      Pkg::Util::RakeUtils.invoke_task("pl:sign_rpms", "repos")
      Pkg::Rpm::Repo.create_repos('repos')
      Pkg::Rpm::Repo.sign_repos('repos')
      Pkg::Deb::Repo.sign_repos('repos', 'Apt repository for signed builds')
      Pkg::OSX.sign('repos') unless Dir['repos/apple/**/*.dmg'].empty?
    end

    task :ship_signed_repos, [:target_prefix] => "pl:fetch" do |t, args|
      target_prefix = args.target_prefix or fail ":target_prefix is a required argument for #{t}"
      target_dir = "#{Pkg::Config.jenkins_repo_path}/#{Pkg::Config.project}/#{Pkg::Config.ref}/#{target_prefix}_repos"
      Pkg::Util::Execution.retry_on_fail(:times => 3) do
        # Ship the now signed repos to the distribution server
        Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "mkdir -p #{target_dir}")
        Pkg::Util::Net.rsync_to("#{target_prefix}_repos/", Pkg::Config.distribution_server, target_dir)
      end
    end

    # This task should be invoked after prepare_signed_repos, so that there are repos to pack up.
    task :pack_signed_repo, [:path_to_repo, :name_of_archive, :versioning] => ["pl:fetch"] do |t, args|
      # path_to_repo should be relative to ./pkg
      path_to_repo = args.path_to_repo or fail ":path_to_repo is a required argument for #{t}"
      name_of_archive = args.name_of_archive or fail ":name_of_archive is a required argument for #{t}"
      versioning = args.versioning or fail ":versioning is a required argument for #{t}"
      tar = Pkg::Util::Tool.check_tool('tar')

      Dir.chdir("pkg") do
        if versioning == 'ref'
          local_target = File.join(Pkg::Config.project, Pkg::Config.ref)
        elsif versioning == 'version'
          local_target = File.join(Pkg::Config.project, Pkg::Util::Version.get_dot_version)
        end

        Dir.chdir(local_target) do
          if Pkg::Util::File.empty_dir?(path_to_repo)
            warn "Skipping #{name_of_archive} because it (#{path_to_repo}) has no files"
          else
            Pkg::Util::Execution.ex("#{tar} --owner=0 --group=0 --create --gzip --file #{File.join("repos", "#{name_of_archive}.tar.gz")} #{path_to_repo}")
          end
        end
      end
    end

    task :prepare_signed_repos, [:target_host, :target_prefix, :versioning] => ["clean", "pl:fetch"] do |t, args|
      target_host = args.target_host or fail ":target_host is a required argument to #{t}"
      target_prefix = args.target_prefix or fail ":target_prefix is a required argument for #{t}"
      versioning = args.versioning or fail ":versioning is a required argument for #{t}"
      mkdir("pkg")

      Dir.chdir("pkg") do
        if versioning == 'ref'
          local_target = File.join(Pkg::Config.project, Pkg::Config.ref)
        elsif versioning == 'version'
          local_target = File.join(Pkg::Config.project, Pkg::Util::Version.get_dot_version)
        end

        FileUtils.mkdir_p([local_target, Pkg::Config.project + "-latest"])

        # Rake task dependencies with arguments are nuts, so we just directly
        # invoke them here.  We want the signed_* directories staged as
        # repos/repo_configs, because that's how we want them on the public
        # server
        Pkg::Util::RakeUtils.invoke_task("pl:jenkins:retrieve", "#{target_prefix}_repos", File.join(local_target, "repos"))
        Pkg::Util::RakeUtils.invoke_task("pl:jenkins:retrieve", "#{target_prefix}_repo_configs", File.join(local_target, "repo_configs"))

        # The repo configs have Pkg::Config.builds_server used in them, but that
        # is internal, so we need to replace it with our public server. We also
        # want them only to see repos, and not signed repos, since the host is
        # called nightlies.puppetlabs.com. Here we replace those values in each
        # config with the desired value.
        Dir.glob("#{local_target}/repo_configs/**/*").select { |t_config| File.file?(t_config) }.each do |config|
          new_contents = File.read(config).gsub(Pkg::Config.builds_server, target_host).gsub(/#{target_prefix}_repos/, "repos")
          File.open(config, "w") { |file| file.puts new_contents }
        end

        # Latest repo work. This little section does some magic to munge the
        # repo configs and link in the latest repos.  The repo_configs are
        # renamed to project-latest-$platform.{list,repo} to ensure that their
        # names stay the same between runs. Their contents have the ref
        # stripped off and the project replaced by $project-latest. Then the
        # repos directory is a symlink to the last pushed ref's repos.
        cp_pr(File.join(local_target, "repo_configs"), Pkg::Config.project + "-latest")

        # Now we need to remove the ref and replace $project with
        # $project-latest so that it will work as a pinned latest repo
        # Also rename the repo config to a static filename.
        Dir.glob("#{Pkg::Config.project}-latest/repo_configs/**/*").select { |t_config| File.file?(t_config) }.each do |config|
          new_contents = File.read(config)
          new_contents.gsub!(%r{#{Pkg::Config.ref}/}, "")
          new_contents.gsub!(%r{#{Pkg::Config.project}/}, Pkg::Config.project + "-latest/")
          new_contents.gsub!(Pkg::Config.ref, "latest")

          File.open(config, "w") { |file| file.puts new_contents }
          FileUtils.mv(config, config.gsub(Pkg::Config.ref, "latest"))
        end

        # If we're using the version strategy instead of ref, here we shuffle
        # around directories and munge repo_configs to replace the ref with the
        # version. In the case that get_dot_version and ref are the same, we
        # have nothing to do, so the conditional is skipped.
        if versioning == 'version' && Pkg::Util::Version.get_dot_version != Pkg::Config.ref
          Dir.glob("#{local_target}/repo_configs/**/*").select { |t_config| File.file?(t_config) }.each do |config|
            new_contents = File.read(config)
            new_contents.gsub!(%r{#{Pkg::Config.ref}}, Pkg::Util::Version.get_dot_version)

            File.open(config, "w") { |file| file.puts new_contents }
            FileUtils.mv(config, config.gsub(Pkg::Config.ref, Pkg::Util::Version.get_dot_version))
          end
        end

        # Make a latest symlink for the project
        FileUtils.ln_s(File.join("..", local_target, "repos"), File.join(Pkg::Config.project + "-latest", "repos"))
      end
    end

    task :deploy_signed_repos, [:target_host, :target_basedir, :foss_only] => "pl:fetch" do |t, args|
      target_host = args.target_host or fail ":target_host is a required argument to #{t}"
      target_basedir = args.target_basedir or fail ":target_basedir is a required argument to #{t}"
      include_paths = []

      if args.foss_only && !Pkg::Config.foss_platforms.empty?
        Pkg::Config.foss_platforms.each do |platform|
          include_paths << Pkg::Util::Platform.repo_path(platform)
          if Pkg::Util::Platform.repo_config_path(platform)
            include_paths << Pkg::Util::Platform.repo_config_path(platform)
          end
        end
      else
        include_paths = ["./"]
      end

      # Ship it to the target for consumption
      # First we ship the latest and clean up any repo-configs that are no longer valid with --delete-after
      Pkg::Util::Execution.ex(%(find #{include_paths.map { |path| "pkg/#{Pkg::Config.project}-latest/#{path}" }.join(' ') } | sort > include_file_latest))
      Pkg::Util::Execution.ex(%(mkdir -p tmp_latest && tar -T include_file_latest -cf - | (cd ./tmp_latest && tar -xf -)))
      Pkg::Util::Net.rsync_to("tmp_latest/pkg/#{Pkg::Config.project}-latest", target_host, target_basedir, ["--delete-after"])
      # Then we ship the sha version with default rsync flags
      Pkg::Util::Execution.ex(%(find #{include_paths.map { |path| "pkg/#{Pkg::Config.project}/**/#{path}" }.join(' ') } | sort > include_file))
      Pkg::Util::Execution.ex(%(mkdir -p tmp && tar -T include_file -cf - | (cd ./tmp && tar -xf -)))
      Pkg::Util::Net.rsync_to("tmp/pkg/#{Pkg::Config.project}", target_host, target_basedir)

      puts "'#{Pkg::Config.ref}' of '#{Pkg::Config.project}' has been shipped to '#{target_host}:#{target_basedir}'"
    end

    task :deploy_signed_repos_to_s3, [:target_bucket] => "pl:fetch" do |t, args|
      target_bucket = args.target_bucket or fail ":target_bucket is a required argument to #{t}"

      # Ship it to the target for consumption
      # First we ship the latest and clean up any repo-configs that are no longer valid with --delete-removed and --acl-public
      Pkg::Util::Net.s3sync_to("pkg/#{Pkg::Config.project}-latest/", target_bucket, "#{Pkg::Config.project}-latest", ["--acl-public", "--delete-removed", "--follow-symlinks"])
      # Then we ship the sha version with just --acl-public
      Pkg::Util::Net.s3sync_to("pkg/#{Pkg::Config.project}/", target_bucket, Pkg::Config.project, ["--acl-public", "--follow-symlinks"])

      puts "'#{Pkg::Config.ref}' of '#{Pkg::Config.project}' has been shipped via s3 to '#{target_bucket}'"
    end

    task :generate_signed_repo_configs, [:target_prefix] => "pl:fetch" do |t, args|
      target_prefix = args.target_prefix or fail ":target_prefix is a required argument for #{t}"
      Pkg::Rpm::Repo.generate_repo_configs("#{target_prefix}_repos", "#{target_prefix}_repo_configs", true)
      Pkg::Deb::Repo.generate_repo_configs("#{target_prefix}_repos", "#{target_prefix}_repo_configs")
    end

    task :ship_signed_repo_configs, [:target_prefix] => "pl:fetch" do |t, args|
      target_prefix = args.target_prefix or fail ":target_prefix is a required argument for #{t}"
      Pkg::Rpm::Repo.ship_repo_configs("#{target_prefix}_repo_configs")
      Pkg::Deb::Repo.ship_repo_configs("#{target_prefix}_repo_configs")
    end

    task :generate_signed_repos, [:target_prefix] => ["pl:fetch"] do |t, args|
      target_prefix = args.target_prefix || 'nightly'
      ["pl:jenkins:remote_sign_repos", "pl:jenkins:ship_signed_repos", "pl:jenkins:generate_signed_repo_configs", "pl:jenkins:ship_signed_repo_configs"].each do |task|
        Pkg::Util::RakeUtils.invoke_task(task, target_prefix)
      end
      puts "Shipped '#{Pkg::Config.ref}' (#{Pkg::Config.version}) of '#{Pkg::Config.project}' into the puppet-agent repos."
    end

    task :nightly_repos => ["pl:fetch"] do
      Pkg::Util::RakeUtils.invoke_task("pl:jenkins:generate_signed_repos", 'nightly')
    end

    task :deploy_nightly_repos, [:target_host, :target_basedir] => ["pl:fetch"] do |t, args|
      target_host = args.target_host or fail ":target_host is a required argument to #{t}"
      target_basedir = args.target_basedir or fail ":target_basedir is a required argument to #{t}"
      Pkg::Util::RakeUtils.invoke_task("pl:jenkins:prepare_signed_repos", target_host, 'nightly', 'ref')
      Pkg::Util::RakeUtils.invoke_task("pl:jenkins:deploy_signed_repos", target_host, target_basedir, true)
    end

    task :deploy_repos_to_s3, [:target_bucket] => ["pl:fetch"] do |t, args|
      target_bucket = args.target_bucket or fail ":target_bucket is a required argument to #{t}"
      target_host = "https://s3.amazonaws.com/#{target_bucket}"
      Pkg::Util::RakeUtils.invoke_task("pl:jenkins:prepare_signed_repos", target_host, 'signed', 'version')
      Pkg::Util::RakeUtils.invoke_task("pl:jenkins:deploy_signed_repos_to_s3", target_bucket)
    end
  end
end
