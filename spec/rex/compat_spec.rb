require 'spec_helper'

describe Rex::Compat do
  describe ".is_windows" do
    before(:each) do
      described_class.class_variable_set(:@@is_windows, false)
    end

    [
      { ruby_platform: 'x64-mingw32', expected: true },
      { ruby_platform: 'x64-mingw-ucrt', expected: true },
      { ruby_platform: 'x86_64-darwin20', expected: false },
    ].each do |test|
      it "correctly identifies #{test[:ruby_platform]} as windows=#{test[:expected]}" do
        stub_const('RUBY_PLATFORM', test[:ruby_platform])
        expect(described_class.is_windows).to eq test[:expected]
      end
    end
  end
end
