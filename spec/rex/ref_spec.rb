# frozen_string_literal: true

require 'spec_helper'
require 'rex/sync/ref'

RSpec.shared_examples 'Rex::Ref' do
  describe '#clone' do
    it { expect { subject.clone }.to raise_exception TypeError, /can't clone instance of Ref/ }
  end

  describe '#dup' do
    it { expect { subject.dup }.to raise_exception TypeError, /can't dup instance of Ref/ }
  end

  describe '#ref' do
    it 'returns the subject when incrementing a ref' do
      expect(subject.ref).to be(subject.ref)
    end

    it 'increments the ref count' do
      expect { subject.ref }.to change { subject.instance_variable_get(:@_references) }.from(1).to(2)
    end
  end

  describe '#deref' do
    before(:each) do
      allow(subject).to receive(:cleanup)
    end

    it 'returns false when there are no more references' do
      _new_ref = subject.ref

      expect(subject.deref).to be(false)
    end

    it 'returns true when there are no more references' do
      expect(subject.deref).to be(true)
    end

    it 'decrements the ref count' do
      expect { subject.deref }.to change { subject.instance_variable_get(:@_references) }.from(1).to(0)
    end

    it 'invokes the cleanup method' do
      subject.deref
      expect(subject).to have_received(:cleanup)
    end
  end
end

RSpec.describe Rex::Ref do
  context 'when included in a class' do
    subject do
      described_mixin = described_class
      klass = Class.new do
        include described_mixin
      end
      klass.new.tap(&:refinit)
    end

    it_behaves_like 'Rex::Ref'
  end

  context 'when extended on an object' do
    subject do
      object = Object.new
      object.extend(described_class)
    end

    it_behaves_like 'Rex::Ref'
  end
end
