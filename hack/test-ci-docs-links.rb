require 'html-proofer'
require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'webrick'

config_path = File.expand_path('../ci-operator/config/openshift/ci-docs/openshift-ci-docs-main.yaml', __dir__)
CI_DOCS_LINKS_COMMANDS = YAML.load_file(config_path).fetch('tests').find { |test| test.fetch('as') == 'links' }.fetch('commands')
CI_DOCS_LINKS_RUBY = CI_DOCS_LINKS_COMMANDS.lines[1...-2].join.sub(/^proofer.run$/, 'proofer')

module CiDocsLinksTestSleep
    def sleep(delay)
        CiDocsLinksTest.delays << delay
    end
end

class CiDocsLinksTest < Minitest::Test
    def setup
        @requests = []
        @responses = {}
        @server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                         Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
        @server.mount_proc('/') do |request, response|
            url, responses = @responses.fetch(request.path)
            @requests << [url, request.request_method.downcase.to_sym]
            options = responses.length > 1 ? responses.shift : responses.first
            sleep(options.fetch(:delay, 0))
            response.status = options.fetch(:code)
            response.body = ''
        end
        @base_url = "http://127.0.0.1:#{@server.config[:Port]}"
        @server_thread = Thread.new { @server.start }
    end

    def teardown
        @server.shutdown
        @server_thread.join
    end

    def check_links(links)
        Dir.mktmpdir do |directory|
            File.write(File.join(directory, 'index.html'), links.map do |link|
                %(<a href="#{link.sub('https://example.com', @base_url)}">link</a>)
            end.join)
            Dir.chdir(directory) do
                proofer = eval(CI_DOCS_LINKS_RUBY, TOPLEVEL_BINDING, 'ci-docs links commands')
                options = proofer.instance_variable_get(:@options)
                assert_equal 1, options.fetch(:hydra).fetch(:max_concurrency)
                assert_equal true, options.fetch(:check_sri)
                assert_equal [403, 405, 429], options.fetch(:http_status_ignore)
                assert_equal 10, options.fetch(:typhoeus).fetch(:connecttimeout)
                assert_equal 30, options.fetch(:typhoeus).fetch(:timeout)
                options[:typhoeus][:timeout_ms] = 100 if @timeout_test
                HTMLProofer::UrlValidator.prepend(CiDocsLinksTestSleep)
                self.class.delays.clear
                begin
                    proofer.run
                    0
                rescue SystemExit => error
                    error.status
                end
            end
        end
    end

    def self.delays
        @delays ||= []
    end

    def serve_link(url, responses)
        @responses[URI(url).path] = [url, responses]
    end

    def test_temporary_http_failures_recover_without_rechecking_healthy_links
        [500, 502, 503, 504].each do |code|
            @requests.clear
            serve_link('https://example.com/healthy', [{ code: 200 }])
            serve_link('https://example.com/retry', [{ code: code }, { code: code }, { code: 200 }])
            assert_equal 0, check_links(['https://example.com/healthy', 'https://example.com/retry'])
            assert_equal 1, @requests.count { |url, _method| url.end_with?('/healthy') }
            assert_equal 3, @requests.count { |url, _method| url.end_with?('/retry') }
            assert_equal [1, 2], self.class.delays
        end
    end

    def test_timeout_recovers
        @timeout_test = true
        serve_link('https://example.com/timeout', [{ code: 200, delay: 0.3 }, { code: 200 }])
        assert_equal 0, check_links(['https://example.com/timeout'])
        assert_equal 2, @requests.length
        assert_equal [1], self.class.delays
    end

    def test_persistent_timeout_fails
        @timeout_test = true
        serve_link('https://example.com/timeout', [{ code: 200, delay: 0.3 }])
        assert_equal 1, check_links(['https://example.com/timeout'])
        assert_equal 3, @requests.length
        assert_equal [1, 2], self.class.delays
    end

    def test_persistent_503_fails_with_shared_head_get_budget
        serve_link('https://example.com/unavailable', [{ code: 503 }])
        assert_equal 1, check_links(['https://example.com/unavailable'])
        assert_equal [:head, :head, :head, :get], @requests.map(&:last)
        assert_equal [1, 2], self.class.delays
    end

    def test_get_fallback_can_retry
        serve_link('https://example.com/fallback', [{ code: 404 }, { code: 503 }, { code: 200 }])
        assert_equal 0, check_links(['https://example.com/fallback'])
        assert_equal [:head, :get, :get], @requests.map(&:last)
        assert_equal [1], self.class.delays
    end

    def test_retry_budget_is_shared_across_methods
        serve_link('https://example.com/shared', [{ code: 503 }, { code: 404 }, { code: 503 }, { code: 503 }])
        assert_equal 1, check_links(['https://example.com/shared'])
        assert_equal [:head, :head, :get, :get], @requests.map(&:last)
        assert_equal [1, 2], self.class.delays
    end

    def test_404_fails_without_retries
        serve_link('https://example.com/missing', [{ code: 404 }])
        assert_equal 1, check_links(['https://example.com/missing'])
        assert_equal [:head, :get], @requests.map(&:last)
        assert_empty self.class.delays
    end

    def test_existing_status_ignores_are_preserved
        [403, 405, 429].each do |code|
            @requests.clear
            serve_link('https://example.com/ignored', [{ code: code }])
            assert_equal 0, check_links(['https://example.com/ignored'])
            assert_equal 1, @requests.length
            assert_empty self.class.delays
        end
    end

    def test_local_broken_link_still_fails
        assert_equal 1, check_links(['missing.html'])
        assert_empty @requests
        assert_empty self.class.delays
    end

    def test_unmodified_shell_command_retries_and_preserves_failures
        serve_link('https://example.com/shell', [{ code: 503 }, { code: 200 }])
        Dir.mktmpdir do |directory|
            Dir.chdir(directory) do
                File.write('index.html', %(<a href="#{@base_url}/shell">link</a>))
                assert system('sh', '-c', CI_DOCS_LINKS_COMMANDS)
                assert_equal [:head, :head], @requests.map(&:last)
                serve_link('https://example.com/shell', [{ code: 404 }])
                refute system('sh', '-c', CI_DOCS_LINKS_COMMANDS)
                assert_equal 1, $?.exitstatus
                File.write('index.html', '<a href="missing.html">link</a>')
                refute system('sh', '-c', CI_DOCS_LINKS_COMMANDS)
                assert_equal 1, $?.exitstatus
            end
        end
    end
end
