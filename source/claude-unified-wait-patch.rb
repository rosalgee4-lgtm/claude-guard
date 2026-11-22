class UnifiedMigration
  alias_method :run_before_wait, :run
  def run(*args)
    result = run_before_wait(*args)
    if args[0] == "/bin/launchctl" && args[1] == "bootout"
      label = args[2].split("/").last
      100.times do
        return result unless loaded(label)
        sleep 0.2
      end
      raise "Unload timeout: #{label}"
    end
    result
  end
end
