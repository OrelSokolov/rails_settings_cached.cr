# Порт test/validation_test.rb из rails-settings-cached 2.9.5.
# Адаптации: errors.full_messages_for(key) → where(key).map(&.message);
# find_or_initialize_by → явный find/new.

require "./spec_helper"

describe "ValidationTest (порт validation_test.rb)" do
  before_all { reset_db! }
  Spec.before_each { reset_state! }

  it "validation" do
    setting = Setting.find_by(var: "host") || Setting.new(var: "host")
    setting.valid?.should be_false
    setting.errors.size.should eq(1)
    setting.errors.where("host").map(&.message).should eq(["can't be blank"])
    setting.value = "https://ruby-china.org"
    setting.valid?.should be_true
    setting.errors.size.should eq(0)

    setting = Setting.find_by(var: "user_limits") || Setting.new(var: "user_limits")
    setting.valid?.should be_false
    setting.errors.size.should eq(2)
    setting.errors.where("user_limits").map(&.message)
      .should eq(["can't be blank", "must be numbers"])
    setting.value = "hello"
    setting.valid?.should be_false
    setting.errors.where("user_limits").map(&.message)
      .should eq(["must be numbers"])
    setting.value = "100"
    setting.valid?.should be_true
    setting.errors.size.should eq(0)

    setting = Setting.find_by(var: "mailer_provider") || Setting.new(var: "mailer_provider")
    setting.valid?.should be_false
    setting.errors.size.should eq(2)
    setting.errors.where("mailer_provider").map(&.message)
      .should eq(["can't be blank", "is not included in the list"])
    setting.value = "hello"
    setting.valid?.should be_false
    setting.errors.size.should eq(1)
    setting.errors.where("mailer_provider").map(&.message)
      .should eq(["is not included in the list"])
    setting.value = "smtp"
    setting.valid?.should be_true
    setting.errors.size.should eq(0)
  end

  it "validation with assignment" do
    ex = expect_raises(ActiveRecord::RecordInvalid) { Setting.host = "" }
    ex.message.should eq("Validation failed: Host can't be blank")

    Setting.host = "foo"

    ex = expect_raises(ActiveRecord::RecordInvalid) { Setting.mailer_provider = "foo" }
    ex.message.should eq("Validation failed: Mailer provider is not included in the list")

    Setting.host = "smtp"
  end
end
