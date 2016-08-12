require 'spec_helper'

describe Rex::Core do
  it 'has a version number' do
    expect(Rex::Core::VERSION).not_to be nil
  end

  it 'does something useful' do
    expect(false).to eq(true)
  end
end
