require "spec"
require "../src/crystalline/main"

describe Crystalline::EnvironmentConfig do
  describe ".unquote_env_value" do
    it "passes unquoted values through" do
      Crystalline::EnvironmentConfig.unquote_env_value("/usr/lib/crystal").should eq("/usr/lib/crystal")
    end

    it "strips simple single-quoted values" do
      Crystalline::EnvironmentConfig.unquote_env_value("'-Dfoo'").should eq("-Dfoo")
    end

    it "decodes empty quoted values" do
      Crystalline::EnvironmentConfig.unquote_env_value("''").should eq("")
    end

    it "decodes single quotes escaped as \"'\"" do
      Crystalline::EnvironmentConfig.unquote_env_value(%q{'a'"'"'b'}).should eq("a'b")
    end

    it "keeps double quotes inside single-quoted values" do
      Crystalline::EnvironmentConfig.unquote_env_value(%q{'a"b'}).should eq("a\"b")
    end

    it "leaves malformed quoting untouched" do
      Crystalline::EnvironmentConfig.unquote_env_value("'unterminated").should eq("'unterminated")
      Crystalline::EnvironmentConfig.unquote_env_value("unopened'").should eq("unopened'")
    end
  end

  describe ".parse_crystal_env_output" do
    it "keeps '=' characters inside env values" do
      # A value containing '=' (e.g. `CRYSTAL_OPTS='-Dfoo=1'`) must not be
      # truncated at the second '=': a truncated value would keep its
      # opening quote, and the next `crystal env` run would re-escape it,
      # growing the variable until subprocess spawning fails with E2BIG.
      result = Crystalline::EnvironmentConfig.parse_crystal_env_output(
        "CRYSTAL_PATH='/usr/lib/crystal'\nCRYSTAL_OPTS='-Dfoo=1'\n"
      )
      result["CRYSTAL_OPTS"].should eq("-Dfoo=1")
      result["CRYSTAL_PATH"].should eq("/usr/lib/crystal")
    end
  end
end
