require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/lightweight/prelude_index"

describe Crystalline::Lightweight::PreludeIndex do
  it "round-trips the prelude index through the cache format" do
    original = Crystalline::Lightweight::PreludeIndex.generate
    original.should_not be_nil
    original = original.not_nil!
    original.types.size.should be > 500
    original.types["String"]?.should_not be_nil

    path = File.join(Dir.tempdir, "crystalline-prelude-test-#{Random::Secure.hex(8)}.bin")
    begin
      Crystalline::Lightweight::PreludeIndex.save_to_cache_for_test(original, path)
      loaded = Crystalline::Lightweight::PreludeIndex.load_from_cache_for_test(path)
      loaded.should_not be_nil
      loaded = loaded.not_nil!

      loaded.types.size.should eq(original.types.size)
      loaded.top_level_methods.size.should eq(original.top_level_methods.size)

      string_type = loaded.types["String"].should_not be_nil
      string_type.methods.map(&.name).should contain("upcase")
      string_type.methods.map(&.name).should contain("split")
      string_type.parent_types.should contain("Reference")

      # Restrictions and return types survive the round trip.
      to_i = string_type.methods.find(&.name.==("to_i"))
      to_i.should_not be_nil
      to_i.not_nil!.args.first.name.should eq("base")
      to_i.not_nil!.args.first.restriction.should eq("Int")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "indexes aliases with the aliased type as their parent" do
    index = Crystalline::Lightweight::PreludeIndex.generate
    index.should_not be_nil
    index = index.not_nil!

    mutex = index.types["Mutex"]?
    mutex.should_not be_nil
    mutex.not_nil!.kind.should eq(Crystalline::Lightweight::TypeKind::Alias)
    mutex.not_nil!.parent_types.should contain("Sync::Mutex")
  end
end
