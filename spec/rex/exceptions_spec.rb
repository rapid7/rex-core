require 'rspec'
require 'rex/exceptions'

RSpec.shared_examples 'Rex::Exception#to_s' do
  it 'provides a default error message' do
    expect(described_class.new.to_s).to eq(default_exception_message)
  end

  it 'allows setting a custom error message' do
    expect(described_class.new('custom message').to_s).to eq('custom message')
  end

  it 'defaults to the default message when the custom message is nil' do
    expect(described_class.new(nil).to_s).to eq(described_class.to_s)
  end
end

RSpec.describe Rex do
  describe Rex::TimeoutError do
    it_behaves_like 'Rex::Exception#to_s' do
      let(:default_exception_message) do
        'Operation timed out.'
      end
    end
  end

  describe Rex::NotImplementedError do
    it_behaves_like 'Rex::Exception#to_s' do
      let(:default_exception_message) do
        'The requested method is not implemented.'
      end
    end
  end

  describe Rex::RuntimeError do
    it_behaves_like 'Rex::Exception#to_s' do
      let(:default_exception_message) do
        described_class.to_s
      end
    end
  end

  describe Rex::ArgumentParseError do
    it_behaves_like 'Rex::Exception#to_s' do
      let(:default_exception_message) do
        'The argument could not be parsed correctly.'
      end
    end
  end

  describe Rex::ArgumentParseError do
    it_behaves_like 'Rex::Exception#to_s' do
      let(:default_exception_message) do
        'The argument could not be parsed correctly.'
      end
    end
  end
end
