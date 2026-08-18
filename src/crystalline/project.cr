require "yaml"
require "uri"
require "./ext/uri"
require "./lightweight/index"
require "./lightweight/summary"

class Crystalline::Project
  # The project root filesystem uri.
  getter root_uri : URI
  # Lightweight top-level semantic index for interactive features.
  property lightweight_index : Crystalline::Lightweight::Index?
  # Compiler-backed semantic summary built from the last successful full compile.
  property semantic_summary : Crystalline::Lightweight::Summary?
  # The dependencies of the project, meaning the list of files required by the compilation target (entry point).
  property dependencies : Set(String) = Set(String).new
  # Parse-only index of the project's own source files (src/ + lib/), built
  # lazily before the first compile so receivers of project types resolve
  # during the cold-start window. Invalidated when a project file is saved
  # or closed.
  @source_index : Crystalline::Lightweight::Index?

  def source_index : Crystalline::Lightweight::Index?
    @source_index ||= build_source_index
  end

  def source_index=(index : Crystalline::Lightweight::Index?)
    @source_index = index
  end

  # Determines the project entry point.
  getter? entry_point : URI? do
    shard_name = shard_yaml["name"].as_s
    # If shard.yml has the `crystalline/main` key, use that.
    relative_main = shard_yaml.dig?("crystalline", "main").try &.as_s
    # Else if shard.yml has a `targets/[shard name]/main` key, use that.
    relative_main ||= shard_yaml.dig?("targets", shard_name, "main").try &.as_s
    if relative_main && File.exists? Path[root_uri.decoded_path, relative_main]
      main_path = Path[root_uri.decoded_path, relative_main]
      # Add the entry point as a dependency to itself.
      dependencies << main_path.to_s
      URI.parse("file://#{main_path}")
    end
  rescue e
    nil
  end
  # Flags to pass to the underlying compiler (e.g. -Dexecution_context).
  getter flags : Array(String) do
    (shard_yaml.dig?("crystalline", "flags").try(&.as_a.map(&.as_s)) || [] of String).tap do |flags|
      LSP::Log.info { "Flags for project #{root_uri}: #{flags}" }
    end
  end

  private getter shard_yaml : YAML::Any do
    path = Path[root_uri.decoded_path, "shard.yml"]
    shards_yaml = File.open(path) do |file|
      YAML.parse(file)
    end
  end

  def initialize(@root_uri)
  end

  # Finds and returns an array of all projects in the workspace root.
  def self.find_in_workspace_root(workspace_root_uri : URI) : Array(Project)
    root_project = Project.new(workspace_root_uri)
    # First, check for a Crystalline project file.
    begin
      path = Path[workspace_root_uri.decoded_path, "shard.yml"]
      shards_yaml = File.open(path) do |file|
        YAML.parse(file)
      end

      projects = shards_yaml.dig?("crystalline", "projects").try do |pjs|
        Dir.glob(pjs.as_a.map(&.as_s)).reduce([] of Project) do |acc, match|
          path = Path.new(match)

          is_directory = File.directory?(path)
          has_shard_yml = is_directory && File.exists?(Path[path, "shard.yml"])
          is_not_lib = has_shard_yml && path.parent != "lib"

          if is_directory && has_shard_yml && is_not_lib
            normalized_path = Path[workspace_root_uri.decoded_path, path].normalize
            acc << Project.new(URI.parse("file://#{normalized_path}"))
          else
            acc
          end
        end
      end || [] of Project

      projects << root_project
    rescue e
      # Failing that, create a project for the workspace root.
      [root_project]
    end
  end

  # Finds the path-wise distance to the given file URI. If the file URI is not a
  # dependency of this workspace's entry point, returns nil unless
  # *require_dependency* is false (a pure path-based fit used by lightweight
  # queries, which never drives compile targeting or cache invalidation).
  def distance_to_dependency(file_uri : URI, *, require_dependency = true) : Int32?
    relative = Path[file_uri.decoded_path].relative_to?(root_uri.decoded_path)
    return nil if relative.nil?

    if require_dependency && dependencies.present? && !dependencies.includes?(file_uri.decoded_path)
      return nil
    end

    relative.parts.size
  end

  # Path to the shards "lib" path for this project.
  def default_lib_path
    Path[@root_uri.decoded_path, "lib"].to_s
  end

  # Parses every project source file (src/ + lib/) into a single index.
  # No semantic pass: type names, method signatures and docs only, which is
  # enough to complete receivers like `workspace` before the first compile.
  private def build_source_index : Crystalline::Lightweight::Index?
    files = [] of String
    root = @root_uri.decoded_path

    src_dir = Path[root, "src"]
    files.concat(Dir.glob(Path[src_dir, "**", "*.cr"]).sort) if Dir.exists?(src_dir)

    lib_dir = Path[root, "lib"]
    files.concat(Dir.glob(Path[lib_dir, "*", "src", "**", "*.cr"]).sort) if Dir.exists?(lib_dir)

    indexes = [] of Crystalline::Lightweight::Index
    files.each do |file|
      next unless File.file?(file)
      if index = Crystalline::Lightweight::Index.from_source(File.read(file), file)
        indexes << index
      end
    end

    return if indexes.empty?

    LSP::Log.info { "[project] source index: #{indexes.size} files for #{root}" }
    Crystalline::Lightweight::Index.merge(indexes)
  end

  # Finds the best-fitting project to use for the given file. By default only
  # files that are dependencies of a project's entry point match; pass
  # *require_dependency* = false for a pure path-based fit.
  def self.best_fit_for_file(projects : Array(Project), file_uri : URI, *, require_dependency = true) : Project?
    project_distances = projects.compact_map do |p|
      distance = p.distance_to_dependency(file_uri, require_dependency: require_dependency)
      {p, distance} if distance
    end

    project_distances.sort_by(&.[1]).first?.try(&.[0])
  end
end
