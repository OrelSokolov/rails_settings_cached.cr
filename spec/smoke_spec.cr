require "./spec_helper"

describe "smoke" do
  it "compiles and answers defaults" do
    reset_db!
    Setting.host.should eq("http://example.com")
  end
end
