# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Octonotify::Poller do
  let(:notify_after) { '2024-01-01T00:00:00Z' }
  let(:default_repos) { { 'owner/repo' => { events: ['release'] } } }
  let(:config) { instance_double(Octonotify::Config, repos: default_repos) }
  let(:client) { instance_double(Octonotify::GraphQLClient) }

  def with_state_file(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'state.json')
      File.write(path, content.to_json)
      state = Octonotify::State.new(state_path: path)
      poller = described_class.new(config: config, state: state, client: client)
      yield poller, state
    end
  end

  def default_state(overrides = {})
    {
      'initialized_at' => notify_after,
      'notify_after' => notify_after,
      'repos' => {}
    }.merge(overrides)
  end

  def release_response(nodes:, has_next_page: false, end_cursor: nil, remaining: 4999)
    {
      'repository' => {
        'releases' => {
          'pageInfo' => { 'hasNextPage' => has_next_page, 'endCursor' => end_cursor },
          'nodes' => nodes
        }
      },
      'rateLimit' => { 'cost' => 1, 'remaining' => remaining, 'resetAt' => '2024-01-15T13:00:00Z' }
    }
  end

  def pr_response(nodes:, has_next_page: false, end_cursor: nil, remaining: 4999)
    {
      'repository' => {
        'pullRequests' => {
          'pageInfo' => { 'hasNextPage' => has_next_page, 'endCursor' => end_cursor },
          'nodes' => nodes
        }
      },
      'rateLimit' => { 'cost' => 1, 'remaining' => remaining, 'resetAt' => '2024-01-15T13:00:00Z' }
    }
  end

  def issue_response(nodes:, has_next_page: false, end_cursor: nil, remaining: 4999)
    {
      'repository' => {
        'issues' => {
          'pageInfo' => { 'hasNextPage' => has_next_page, 'endCursor' => end_cursor },
          'nodes' => nodes
        }
      },
      'rateLimit' => { 'cost' => 1, 'remaining' => remaining, 'resetAt' => '2024-01-15T13:00:00Z' }
    }
  end

  describe '#poll' do
    context 'with new releases' do
      it 'returns new events and updates state' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_123',
              'name' => 'v1.0.0',
              'tagName' => 'v1.0.0',
              'url' => 'https://github.com/owner/repo/releases/tag/v1.0.0',
              'publishedAt' => '2024-01-15T12:00:00Z'
            }
          ])
        )

        with_state_file(default_state) do |poller, state|
          result = poller.poll

          expect(result[:events].size).to eq(1)
          expect(result[:events].first).to have_attributes(
            type: 'release',
            repo: 'owner/repo',
            id: 'RE_123',
            title: 'v1.0.0',
            url: 'https://github.com/owner/repo/releases/tag/v1.0.0',
            extra: { tag_name: 'v1.0.0' }
          )
          expect(result[:incomplete]).to eq(false)
          expect(result[:rate_limit]).to include('remaining' => 4999)

          # Verify state side effects
          expect(state.notified?('owner/repo', 'release', 'RE_123')).to eq(true)
          event_state = state.event_state('owner/repo', 'release')
          expect(event_state['watermark_time']).to eq('2024-01-15T12:00:00Z')
        end
      end
    end

    context 'with pull_request_merged event type' do
      let(:default_repos) { { 'owner/repo' => { events: ['pull_request_merged'] } } }

      it 'returns merged PRs with mergedBy in extra' do
        allow(client).to receive(:fetch_merged_pull_requests).and_return(
          pr_response(nodes: [
            {
              'id' => 'PR_123',
              'title' => 'Fix bug',
              'url' => 'https://github.com/owner/repo/pull/1',
              'mergedAt' => '2024-01-15T12:00:00Z',
              'author' => { 'login' => 'alice' },
              'mergedBy' => { 'login' => 'bob' }
            }
          ])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:events].size).to eq(1)
          expect(result[:events].first).to have_attributes(
            type: 'pull_request_merged',
            id: 'PR_123',
            title: 'Fix bug',
            author: 'alice',
            extra: { merged_by: 'bob' }
          )
        end
      end
    end

    context 'with pull_request_created event type' do
      let(:default_repos) { { 'owner/repo' => { events: ['pull_request_created'] } } }

      it 'returns created PRs' do
        allow(client).to receive(:fetch_created_pull_requests).and_return(
          pr_response(nodes: [
            {
              'id' => 'PR_456',
              'title' => 'Add feature',
              'url' => 'https://github.com/owner/repo/pull/2',
              'createdAt' => '2024-01-15T12:00:00Z',
              'author' => { 'login' => 'charlie' }
            }
          ])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:events].size).to eq(1)
          expect(result[:events].first).to have_attributes(
            type: 'pull_request_created',
            id: 'PR_456',
            title: 'Add feature',
            author: 'charlie'
          )
        end
      end
    end

    context 'with issue_created event type' do
      let(:default_repos) { { 'owner/repo' => { events: ['issue_created'] } } }

      it 'returns created issues' do
        allow(client).to receive(:fetch_issues).and_return(
          issue_response(nodes: [
            {
              'id' => 'I_789',
              'title' => 'Bug report',
              'url' => 'https://github.com/owner/repo/issues/1',
              'createdAt' => '2024-01-15T12:00:00Z',
              'author' => { 'login' => 'dave' }
            }
          ])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:events].size).to eq(1)
          expect(result[:events].first).to have_attributes(
            type: 'issue_created',
            id: 'I_789',
            title: 'Bug report',
            author: 'dave'
          )
        end
      end
    end

    context 'with already notified events' do
      it 'skips already notified events' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_123',
              'name' => 'v1.0.0',
              'tagName' => 'v1.0.0',
              'url' => 'https://github.com/owner/repo/releases/tag/v1.0.0',
              'publishedAt' => '2024-01-15T12:00:00Z'
            }
          ])
        )

        state_with_notified = default_state(
          'repos' => {
            'owner/repo' => {
              'url' => 'https://github.com/owner/repo',
              'events' => {
                'release' => {
                  'watermark_time' => notify_after,
                  'recent_notified_ids' => ['RE_123'],
                  'resume_cursor' => nil,
                  'incomplete' => false
                }
              }
            }
          }
        )

        with_state_file(state_with_notified) do |poller, _state|
          result = poller.poll
          expect(result[:events]).to be_empty
        end
      end
    end

    context 'with events before notify_after' do
      it 'skips events before notify_after' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_old',
              'name' => 'v0.9.0',
              'tagName' => 'v0.9.0',
              'url' => 'https://github.com/owner/repo/releases/tag/v0.9.0',
              'publishedAt' => '2023-12-31T12:00:00Z'
            }
          ])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll
          expect(result[:events]).to be_empty
        end
      end
    end

    context 'when repository has no events' do
      it 'returns empty events array' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:events]).to be_empty
          expect(result[:incomplete]).to eq(false)
        end
      end
    end

    context 'when event has nil time field' do
      it 'skips the event' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_draft',
              'name' => 'Draft Release',
              'tagName' => 'v2.0.0-draft',
              'url' => 'https://github.com/owner/repo/releases/tag/v2.0.0-draft',
              'publishedAt' => nil
            }
          ])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll
          expect(result[:events]).to be_empty
        end
      end
    end

    context 'with pagination' do
      it 'fetches all pages until threshold is reached' do
        call_count = 0
        allow(client).to receive(:fetch_releases) do
          call_count += 1
          if call_count == 1
            release_response(
              nodes: [
                {
                  'id' => 'RE_1',
                  'name' => 'v1.0.0',
                  'tagName' => 'v1.0.0',
                  'url' => 'https://github.com/owner/repo/releases/tag/v1.0.0',
                  'publishedAt' => '2024-01-15T12:00:00Z'
                }
              ],
              has_next_page: true,
              end_cursor: 'cursor1'
            )
          else
            release_response(
              nodes: [
                {
                  'id' => 'RE_2',
                  'name' => 'v0.9.0',
                  'tagName' => 'v0.9.0',
                  'url' => 'https://github.com/owner/repo/releases/tag/v0.9.0',
                  'publishedAt' => '2024-01-10T12:00:00Z'
                }
              ],
              has_next_page: false
            )
          end
        end

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:events].size).to eq(2)
          expect(call_count).to eq(2)
        end
      end

      it 'sets resume_cursor when rate limit is hit during pagination' do
        call_count = 0
        allow(client).to receive(:fetch_releases) do
          call_count += 1
          release_response(
            nodes: [
              {
                'id' => "RE_#{call_count}",
                'name' => "v#{call_count}.0.0",
                'tagName' => "v#{call_count}.0.0",
                'url' => "https://github.com/owner/repo/releases/tag/v#{call_count}.0.0",
                'publishedAt' => '2024-01-15T12:00:00Z'
              }
            ],
            has_next_page: true,
            end_cursor: "cursor#{call_count}",
            remaining: 50
          )
        end

        with_state_file(default_state) do |poller, state|
          result = poller.poll

          event_state = state.event_state('owner/repo', 'release')
          expect(event_state['resume_cursor']).to eq('cursor1')
          expect(event_state['incomplete']).to eq(true)
          expect(result[:events].size).to eq(1)
        end
      end

      it 'clears resume_cursor after successful completion' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_123',
              'name' => 'v1.0.0',
              'tagName' => 'v1.0.0',
              'url' => 'https://github.com/owner/repo/releases/tag/v1.0.0',
              'publishedAt' => '2024-01-15T12:00:00Z'
            }
          ])
        )

        state_with_cursor = default_state(
          'repos' => {
            'owner/repo' => {
              'url' => 'https://github.com/owner/repo',
              'events' => {
                'release' => {
                  'watermark_time' => notify_after,
                  'recent_notified_ids' => [],
                  'resume_cursor' => 'old_cursor',
                  'incomplete' => true
                }
              }
            }
          }
        )

        with_state_file(state_with_cursor) do |poller, state|
          poller.poll

          event_state = state.event_state('owner/repo', 'release')
          expect(event_state['resume_cursor']).to be_nil
          expect(event_state['incomplete']).to eq(false)
        end
      end
    end

    context 'with rate limit threshold reached' do
      let(:default_repos) do
        {
          'owner/repo1' => { events: ['release'] },
          'owner/repo2' => { events: ['release'] }
        }
      end

      it 'stops polling and returns incomplete' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(
            nodes: [
              {
                'id' => 'RE_123',
                'name' => 'v1.0.0',
                'tagName' => 'v1.0.0',
                'url' => 'https://github.com/owner/repo1/releases/tag/v1.0.0',
                'publishedAt' => '2024-01-15T12:00:00Z'
              }
            ],
            remaining: 50
          )
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:incomplete]).to eq(true)
          expect(result[:events].size).to eq(1)
          expect(result[:rate_limit]['remaining']).to eq(50)
        end
      end
    end

    context 'with multiple repos and event types' do
      let(:default_repos) do
        {
          'owner/repo1' => { events: %w[release issue_created] },
          'owner/repo2' => { events: ['pull_request_merged'] }
        }
      end

      it 'polls all repos and event types and collects events' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_1',
              'name' => 'v1.0.0',
              'tagName' => 'v1.0.0',
              'url' => 'https://github.com/owner/repo1/releases/tag/v1.0.0',
              'publishedAt' => '2024-01-15T12:00:00Z'
            }
          ])
        )
        allow(client).to receive(:fetch_issues).and_return(
          issue_response(nodes: [
            {
              'id' => 'I_1',
              'title' => 'Issue',
              'url' => 'https://github.com/owner/repo1/issues/1',
              'createdAt' => '2024-01-15T12:00:00Z',
              'author' => { 'login' => 'alice' }
            }
          ])
        )
        allow(client).to receive(:fetch_merged_pull_requests).and_return(
          pr_response(nodes: [
            {
              'id' => 'PR_1',
              'title' => 'PR',
              'url' => 'https://github.com/owner/repo2/pull/1',
              'mergedAt' => '2024-01-15T12:00:00Z',
              'author' => { 'login' => 'bob' },
              'mergedBy' => { 'login' => 'charlie' }
            }
          ])
        )

        with_state_file(default_state) do |poller, _state|
          result = poller.poll

          expect(result[:events].size).to eq(3)
          expect(result[:events].map(&:type)).to contain_exactly(
            'release', 'issue_created', 'pull_request_merged'
          )
          expect(result[:events].map(&:repo)).to contain_exactly(
            'owner/repo1', 'owner/repo1', 'owner/repo2'
          )
        end
      end
    end

    context 'with lookback window' do
      it 'fetches events within watermark minus 30 minutes threshold' do
        # Watermark is at 12:00, so threshold is 11:30
        # Events at 11:35 should be fetched (within lookback)
        # Events at 11:25 should stop fetching (before threshold)
        call_count = 0
        allow(client).to receive(:fetch_releases) do
          call_count += 1
          if call_count == 1
            release_response(
              nodes: [
                {
                  'id' => 'RE_new',
                  'name' => 'v2.0.0',
                  'tagName' => 'v2.0.0',
                  'url' => 'https://github.com/owner/repo/releases/tag/v2.0.0',
                  'publishedAt' => '2024-01-15T12:30:00Z'
                }
              ],
              has_next_page: true,
              end_cursor: 'cursor1'
            )
          else
            release_response(
              nodes: [
                {
                  'id' => 'RE_old',
                  'name' => 'v1.0.0',
                  'tagName' => 'v1.0.0',
                  'url' => 'https://github.com/owner/repo/releases/tag/v1.0.0',
                  'publishedAt' => '2024-01-15T11:25:00Z'
                }
              ],
              has_next_page: true,
              end_cursor: 'cursor2'
            )
          end
        end

        state_with_watermark = default_state(
          'repos' => {
            'owner/repo' => {
              'url' => 'https://github.com/owner/repo',
              'events' => {
                'release' => {
                  'watermark_time' => '2024-01-15T12:00:00Z',
                  'recent_notified_ids' => [],
                  'resume_cursor' => nil,
                  'incomplete' => false
                }
              }
            }
          }
        )

        with_state_file(state_with_watermark) do |poller, _state|
          result = poller.poll

          # Should stop after second page because event is before threshold
          expect(call_count).to eq(2)
          # Only the new event should be returned (old one is before notify_after anyway in this test)
          expect(result[:events].size).to eq(1)
          expect(result[:events].first.id).to eq('RE_new')
        end
      end
    end

    context 'with unknown event type' do
      let(:default_repos) { { 'owner/repo' => { events: ['unknown_event'] } } }

      it 'raises ArgumentError' do
        with_state_file(default_state) do |poller, _state|
          expect { poller.poll }.to raise_error(ArgumentError, /Unknown event type: unknown_event/)
        end
      end
    end

    context 'when resuming from cursor' do
      it 'passes resume_cursor to the API client' do
        allow(client).to receive(:fetch_releases).and_return(
          release_response(nodes: [
            {
              'id' => 'RE_123',
              'name' => 'v1.0.0',
              'tagName' => 'v1.0.0',
              'url' => 'https://github.com/owner/repo/releases/tag/v1.0.0',
              'publishedAt' => '2024-01-15T12:00:00Z'
            }
          ])
        )

        state_with_cursor = default_state(
          'repos' => {
            'owner/repo' => {
              'url' => 'https://github.com/owner/repo',
              'events' => {
                'release' => {
                  'watermark_time' => notify_after,
                  'recent_notified_ids' => [],
                  'resume_cursor' => 'saved_cursor_123',
                  'incomplete' => true
                }
              }
            }
          }
        )

        with_state_file(state_with_cursor) do |poller, _state|
          poller.poll

          expect(client).to have_received(:fetch_releases).with(
            owner: 'owner',
            repo: 'repo',
            first: 25,
            after: 'saved_cursor_123'
          )
        end
      end
    end
  end

  describe 'Event struct' do
    it 'creates immutable event' do
      event = described_class::Event.new(
        type: 'release',
        repo: 'owner/repo',
        id: 'RE_123',
        title: 'v1.0.0',
        url: 'https://example.com',
        time: Time.now,
        author: 'alice',
        extra: { tag_name: 'v1.0.0' }
      )

      expect(event).to be_frozen
      expect(event.type).to eq('release')
      expect(event.extra[:tag_name]).to eq('v1.0.0')
    end
  end
end
