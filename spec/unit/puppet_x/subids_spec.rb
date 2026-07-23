# frozen_string_literal: true

require 'spec_helper'
require File.expand_path('../../../lib/puppet_x/rootless_gitlab_runner/subids', __dir__)

describe PuppetX::RootlessGitlabRunner::Subids do
  describe '.parse' do
    it 'parses one entry into start/count integers' do
      expect(described_class.parse(['gitlab-runner:231072:165536']))
        .to eq('gitlab-runner' => [{ 'start' => 231_072, 'count' => 165_536 }])
    end

    it 'keeps every range when a user owns more than one' do
      expect(described_class.parse(['ci:100000:65536', 'ci:300000:1000'])['ci'])
        .to eq([{ 'start' => 100_000, 'count' => 65_536 }, { 'start' => 300_000, 'count' => 1000 }])
    end

    it 'keeps distinct owners apart (the overlap advisory reads foreign rows)' do
      parsed = described_class.parse(['gitlab-runner:231072:165536', 'sophie:231072:65536'])
      expect(parsed.keys).to contain_exactly('gitlab-runner', 'sophie')
      expect(parsed['sophie']).to eq([{ 'start' => 231_072, 'count' => 65_536 }])
    end

    it 'skips blank, short, and non-numeric lines' do
      lines = ['', 'gitlab-runner', 'foo:bar:65536', 'gitlab-runner:231072:165536']
      expect(described_class.parse(lines)).to eq('gitlab-runner' => [{ 'start' => 231_072, 'count' => 165_536 }])
    end

    it 'tolerates trailing newlines from a real file read' do
      expect(described_class.parse(["gitlab-runner:231072:165536\n"]))
        .to eq('gitlab-runner' => [{ 'start' => 231_072, 'count' => 165_536 }])
    end
  end

  describe '.read' do
    it 'yields an empty map for an unreadable file and parses a readable one' do
      allow(File).to receive(:readable?).with('/x/subuid').and_return(false)
      allow(File).to receive(:readable?).with('/x/subgid').and_return(true)
      allow(File).to receive(:foreach).with('/x/subgid').and_return(['gitlab-runner:231072:165536'])
      result = described_class.read('subuid' => '/x/subuid', 'subgid' => '/x/subgid')
      expect(result['subuid']).to eq({})
      expect(result['subgid']).to eq('gitlab-runner' => [{ 'start' => 231_072, 'count' => 165_536 }])
    end
  end
end
