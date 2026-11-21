# frozen_string_literal: true

# The pinned copy of the specification (sattleme/checkout-spec, its PORTING.md: "The pinned copy
# of the specification"): spec/ holds the files its manifest.json lists, unchanged, and
# spec/PIN.json says which commit they come from, with the SHA-256 of each.
#
#   ruby scripts/spec.rb check
#       Whether spec/ is PIN.json's, file for file (test/spec_pin_test.rb runs it too).
#   ruby scripts/spec.rb import <checkout-spec clone>
#       Replaces spec/ with the files of a clean clone, at the commit it is on, and writes
#       PIN.json. Its manifest.json must be its files'. Clone and check out the version yourself:
#       no network.

require "digest"
require "fileutils"
require "json"
require "open3"

# The pinned copy of checkout-spec in spec/ (PIN.json: its commit, and the SHA-256 of each file):
# checked as it is, or taken again from a newer commit of the repository.
module SpecPin
  REPOSITORY = "https://github.com/sattleme/checkout-spec"
  ROOT = File.expand_path("..", __dir__)
  COPY = File.join(ROOT, "spec")
  PIN = "PIN.json"

  module_function

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  # Every file under `dir`, as paths relative to it with "/", sorted.
  def files_under(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir)
       .reject { |path| [".", ".."].include?(File.basename(path)) }
       .select { |path| File.file?(File.join(dir, path)) }
       .sort
  end

  # What differs between the copy and its PIN.json: empty when the copy is the pinned one.
  def problems(copy = COPY)
    pin_path = File.join(copy, PIN)
    return ["#{PIN} is missing"] unless File.file?(pin_path)

    pin = JSON.parse(File.read(pin_path, encoding: "UTF-8"))
    files = pin["files"].is_a?(Hash) ? pin["files"] : {}
    found = []
    found << "#{PIN}: repository is not #{REPOSITORY}" unless pin["repository"] == REPOSITORY
    found << "#{PIN}: commit is not a commit" unless pin["commit"].to_s.match?(/\A[0-9a-f]{40}\z/)
    files.each do |file, hash|
      path = File.join(copy, file)
      if !File.file?(path)
        found << "#{file} is missing"
      elsif sha256(path) != hash
        found << "#{file} differs from #{PIN}"
      end
    end
    files_under(copy).each do |file|
      found << "#{file} is not in #{PIN}" unless file == PIN || files.key?(file)
    end
    found
  end

  def git(clone, *args)
    out, status = Open3.capture2("git", "-C", clone, *args)
    raise "git #{args.join(" ")} failed in #{clone}" unless status.success?

    out.strip
  end

  # Replaces the copy with the files of the clean clone `clone`, and writes PIN.json.
  def import(clone)
    raise "#{clone} is not clean" unless git(clone, "status", "--porcelain").empty?

    commit = git(clone, "rev-parse", "HEAD")
    manifest = JSON.parse(File.read(File.join(clone, "manifest.json"), encoding: "UTF-8"))
    manifest["files"].each do |file, hash|
      raise "#{file} is not the manifest's" unless sha256(File.join(clone, file)) == hash
    end
    FileUtils.rm_rf(COPY)
    manifest["files"].each_key do |file|
      FileUtils.mkdir_p(File.dirname(File.join(COPY, file)))
      FileUtils.cp(File.join(clone, file), File.join(COPY, file))
    end
    pin = { "repository" => REPOSITORY, "commit" => commit, "version" => manifest["version"],
            "protocol" => manifest["protocol"], "files" => manifest["files"] }
    File.write(File.join(COPY, PIN), "#{JSON.pretty_generate(pin)}\n")
    pin
  end
end

if $PROGRAM_NAME == __FILE__
  command, clone = ARGV
  case command
  when "check"
    found = SpecPin.problems
    found.each { |problem| warn problem }
    exit(found.empty? ? 0 : 1)
  when "import"
    abort "Usage: ruby scripts/spec.rb import <checkout-spec clone>" unless clone
    pin = SpecPin.import(clone)
    puts "spec/ is checkout-spec #{pin["version"]} at #{pin["commit"]}"
  else
    warn "Usage: ruby scripts/spec.rb check | import <checkout-spec clone>"
    exit 2
  end
end
