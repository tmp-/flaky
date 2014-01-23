# encoding: utf-8
module Flaky

  class Cmd
    attr_reader :pid, :in, :out, :err

    def initialize cmd
      # redirect err to child's out
      @pid, @in, @out, @err = POSIX::Spawn::popen4 cmd, {:err => [:child, :out]}
      @in.close
    end

    def stop
      [@in, @out, @err].each { |io| io.close unless io.nil? || io.closed? }
      begin
        Process.kill 'KILL', @pid
        Process.waitpid @pid
      rescue # no such process
      end
    end
  end

  #noinspection RubyResolve
  class Appium
    include POSIX::Spawn
    attr_reader :ready, :pid, :in, :out, :err, :log, :ios, :android
    @@thread = nil

    def self.remove_ios_apps
      user = ENV['USER']
      raise 'User must be defined' unless user

      # Must kill iPhone simulator or strange install errors will occur.
      self.kill_all 'iPhone Simulator'

      app_glob = "/Users/#{user}/Library/Application Support/iPhone Simulator/**/Applications"
      Dir.glob(app_glob) do |ios_app_folder|
        FileUtils.rm_rf ios_app_folder
        root = File.dirname ios_app_folder
        FileUtils.rm_rf File.join(root, 'Library/TCC')
        FileUtils.rm_rf File.join(root, 'Library/Caches')
        FileUtils.rm_rf File.join(root, 'Library/Media')
      end
    end

    def self.kill_all process_name
      begin
        _pid, _in, _out, _err = POSIX::Spawn::popen4('killall', '-9', process_name)
        raise "Unable to kill #{process_name}" unless _pid
        _in.close
        _out.read
        _err.read
      rescue Errno::EAGAIN
      # POSIX::Spawn::popen4 may raise EAGAIN. If it does, retry after a second.
          sleep 1
          retry
      ensure
        [_in, _out, _err].each { |io| io.close unless io.nil? || io.closed? }
        Process::waitpid(_pid) if _pid
      end
    end

    # android: true to activate Android mode
    def initialize opts={}
      @ready = false
      @pid, @in, @out, @err = nil
      @log = ''
      @buffer = ''
      @android = opts.fetch(:android, false)
      @ios = ! @android
    end

    def start
      self.stop # stop existing process
      @log = '/tmp/flaky/appium_tmp_log.txt'
      File.delete(@log) if File.exists? @log

      # appium should reset at startup

      @@thread.exit if @@thread
      @@thread = Thread.new do
        Thread.current.abort_on_exception = true
        self.launch.wait
      end

      begin
        timeout 60 do # timeout in seconds
          while !self.ready
            sleep 0.5
          end
        end
      rescue Timeout::Error
        # try again if appium fails to become ready
        # sometimes the simulator never launches.
        # the sim crashes or any number of issues.
        self.start
      end

      # -e = -A = include other user's processes
      # -a = include your own processes
      # -x = include processes without a controlling terminal
      # ps -eax | grep "tail"
      # http://askubuntu.com/questions/157075/why-does-ps-aux-grep-x-give-better-results-than-pgrep-x
    end

    def update_buffer data
      @buffer += data
      self.flush_buffer
    end

    def flush_buffer
      return @log if @buffer.nil? || @buffer.empty?
      File.open(@log, 'a') do |f|
        f.write @buffer
      end
      @buffer = ''
      @log
    end

    ##
    # Internal methods

    def wait
      out_err = [@out, @err]

      # https://github.com/rtomayko/posix-spawn/blob/1d498232660763ff0db6a2f0ab5c1c47fe593896/lib/posix/spawn/child.rb
      while out_err.any?
        io_array = IO.select out_err, [], out_err
        raise 'Appium never spawned' if io_array.nil?

        ready_for_reading = io_array[0]

        ready_for_reading.each do |stream|
          begin
            capture = stream.readpartial 999_999
            update_buffer(capture) if capture
            @ready = true if !@ready && capture.include?('Appium REST http interface listener started')
          rescue EOFError
            out_err.delete stream
            stream.close
          end
        end
      end
    end

    # if this is defined using self, then instance methods must refer using
    # self.class.end_all_nodes
    # instead self.end_all_nodes is cleaner.
    # https://github.com/rtomayko/posix-spawn#posixspawn-as-a-mixin
    def end_all_nodes
      self.class.kill_all 'node'
    end

    def end_all_instruments
      self.class.kill_all 'instruments'
    end

    # Invoked inside a thread by `self.go`
    def launch
      self.end_all_nodes
      @ready = false
      appium_home = ENV['APPIUM_HOME']
      raise "ENV['APPIUM_HOME'] must be set!" if appium_home.nil? || appium_home.empty?
      contains_appium = File.exists?(File.join(ENV['APPIUM_HOME'], 'bin', 'appium.js'))
      raise "Appium home `#{appium_home}` doesn't contain bin/appium.js!" unless contains_appium
      cmd = %Q(cd "#{appium_home}"; node .)
      @pid, @in, @out, @err = popen4 cmd
      @in.close
      self # used to chain `launch.wait`
    end

    def stop
      # https://github.com/tmm1/pygments.rb/blob/master/lib/pygments/popen.rb
      begin
        Process.kill 'KILL', @pid
      rescue
      end unless @pid.nil?
      @pid = nil
      self.end_all_nodes
      self.end_all_instruments unless @android
    end
  end # class Appium
end # module Flaky