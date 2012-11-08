require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'test_helper'))
require 'new_relic/agent/thread_profiler'

class NewRelicServiceTest < Test::Unit::TestCase
  def initialize(*_)
    [ :HTTPSuccess,
      :HTTPNotFound,
      :HTTPRequestEntityTooLarge,
      :HTTPUnsupportedMediaType ].each do |class_name|
      extend_with_mock(class_name)
    end
    super
  end

  def extend_with_mock(class_name)
    if !self.class.const_defined?(class_name)
      klass = self.class.const_set(class_name,
                Class.new(Object.const_get(:Net).const_get(class_name)))
      klass.class_eval { include HTTPResponseMock }
    end
  end
  protected :extend_with_mock

  def setup
    @server = NewRelic::Control::Server.new('somewhere.example.com',
                                            30303, '10.10.10.10')
    @service = NewRelic::Agent::NewRelicService.new('license-key', @server)
    @http_handle = HTTPHandle.new
    NewRelic::Control.instance.stubs(:http_connection).returns(@http_handle)
    @http_handle.respond_to(:get_redirect_host, 'localhost')
    connect_response = {
      'config' => 'some config directives',
      'agent_run_id' => 1
    }
    @http_handle.respond_to(:connect, connect_response)
  end

  def test_initialize_uses_correct_license_key_settings
    with_config(:license_key => 'abcde') do
      service = NewRelic::Agent::NewRelicService.new
      assert_equal 'abcde', service.instance_variable_get(:@license_key)
    end
  end

  def test_connect_sets_agent_id_and_config_data
    response = @service.connect
    assert_equal 1, response['agent_run_id']
    assert_equal 'some config directives', response['config']
  end

  def test_connect_sets_redirect_host
    assert_equal 'somewhere.example.com', @service.collector.name
    @service.connect
    assert_equal 'localhost', @service.collector.name
  end

  def test_connect_resets_cached_ip_address
    assert_equal '10.10.10.10', @service.collector.ip
    @service.connect
    assert_nil @service.collector.ip # 'localhost' resolves to nil
  end

  def test_connect_uses_proxy_collector_if_no_redirect_host
    @http_handle.reset
    @http_handle.respond_to(:get_redirect_host, nil)
    @http_handle.respond_to(:connect, {'agent_run_id' => 1})

    @service.connect
    assert_equal 'somewhere.example.com', @service.collector.name
  end

  def test_connect_sets_agent_id
    @http_handle.reset
    @http_handle.respond_to(:get_redirect_host, 'localhost')
    @http_handle.respond_to(:connect, {'agent_run_id' => 666})

    @service.connect
    assert_equal 666, @service.agent_id
  end

  def test_get_redirect_host
    host = @service.get_redirect_host
    assert_equal 'localhost', host
  end

  def test_shutdown
    @service.agent_id = 666
    @http_handle.respond_to(:shutdown, 'shut this bird down')
    response = @service.shutdown(Time.now)
    assert_equal 'shut this bird down', response
  end

  def test_should_not_shutdown_if_never_connected
    @http_handle.respond_to(:shutdown, 'shut this bird down')
    response = @service.shutdown(Time.now)
    assert_nil response
  end

  def test_metric_data
    @http_handle.respond_to(:metric_data, 'met rick date uhhh')
    response = @service.metric_data(Time.now - 60, Time.now, {})
    assert_equal 'met rick date uhhh', response
  end

  def test_error_data
    @http_handle.respond_to(:error_data, 'too human')
    response = @service.error_data([])
    assert_equal 'too human', response
  end

  def test_transaction_sample_data
    @http_handle.respond_to(:transaction_sample_data, 'MPC1000')
    response = @service.transaction_sample_data([])
    assert_equal 'MPC1000', response
  end

  def test_sql_trace_data
    @http_handle.respond_to(:sql_trace_data, 'explain this')
    response = @service.sql_trace_data([])
    assert_equal 'explain this', response
  end

  def test_profile_data
    stub_command(:profile_data, 'profile')
    response = @service.profile_data(NewRelic::Agent::ThreadProfile.new(0, 0)) 
    assert_equal 'profile', response.body
  end

  def test_get_agent_commands
    @service.agent_id = 666
    stub_command(:get_agent_commands, '{ "return_value": [1,2,3] }')

    response = @service.get_agent_commands
    assert_equal [1,2,3], response
  end

  def test_get_agent_commands_without_return_value
    @service.agent_id = 666
    stub_command(:get_agent_commands, '{ "unexpected": [] }')

    response = @service.get_agent_commands
    assert_equal [], response
  end

  def test_get_agent_commands_with_no_response
    @service.agent_id = 666
    stub_command(:get_agent_commands, nil)

    response = @service.get_agent_commands
    assert_equal [], response
  end

  def test_agent_command_results
    stub_command(:agent_command_results, 'result')
    response = @service.agent_command_results(4200)
    assert_equal 'result', response.body
  end

  def test_agent_command_results_with_errors
    @http_handle.register(HTTPSuccess.new('returned error', 200)) do |request|
      request.path.include?('agent_command_results') && request.body.include?('Boo!')
    end
    response = @service.agent_command_results(4200, 'Boo!')
    assert_equal 'returned error', response.body
  end

  def stub_command(command, json)
    @http_handle.register(HTTPSuccess.new(json, 200)) do |request|
      request.path.include?(command.to_s)
    end
  end

  def test_request_timeout
    with_config(:timeout => 600) do
      service = NewRelic::Agent::NewRelicService.new('abcdef', @server)
      assert_equal 600, service.request_timeout
    end
  end

  def test_should_throw_received_errors
    assert_raise NewRelic::Agent::ServerConnectionException do
      @service.send(:invoke_remote, :bogus_method)
    end
  end

  def test_should_connect_to_proxy_only_once_per_run
    @service.expects(:get_redirect_host).once

    @service.connect
    @http_handle.respond_to(:metric_data, 0)
    @service.metric_data(Time.now - 60, Time.now, {})

    @http_handle.respond_to(:ransaction_sample_data, '{"return_value": 1}')
    @service.transaction_sample_data([])

    @http_handle.respond_to(:sql_trace_data, 2)
    @service.sql_trace_data([])
  end

  # protocol 9
  def test_should_raise_exception_on_413
    @http_handle.respond_to(:metric_data, 'too big', 413)
    assert_raise NewRelic::Agent::UnrecoverableServerException do
      @service.metric_data(Time.now - 60, Time.now, {})
    end
  end

  # protocol 9
  def test_should_raise_exception_on_415
    @http_handle.respond_to(:metric_data, 'too big', 415)
    assert_raise NewRelic::Agent::UnrecoverableServerException do
      @service.metric_data(Time.now - 60, Time.now, {})
    end
  end

  if NewRelic::LanguageSupport.using_version?('1.9')
    def test_json_marshaller_handles_responses_from_collector
      marshaller = NewRelic::Agent::NewRelicService::JsonMarshaller.new
      assert_equal ['beep', 'boop'], marshaller.load('{"return_value": ["beep","boop"]}')
    end

    def test_json_marshaller_handles_errors_from_collector
      marshaller = NewRelic::Agent::NewRelicService::JsonMarshaller.new
      assert_raise(NewRelic::Agent::NewRelicService::CollectorError,
                   'JavaCrash: error message') do
        marshaller.load('{"exception": {"message": "error message", "error_type": "JavaCrash"}}')
      end
    end
  end

  def test_ruby_marshaller_handles_errors_from_collector
    marshaller = NewRelic::Agent::NewRelicService::RubyMarshaller.new
    assert_raise(RuntimeError, 'error message') do
      marshaller.load(Marshal.dump(RuntimeError.new('error message')))
    end
  end

  def test_ruby_marshaller_compresses_large_payloads
    marshaller = NewRelic::Agent::NewRelicService::RubyMarshaller.new
    large_payload = 'a' * 64 * 1024
    result = marshaller.dump(large_payload)
    assert_equal 'deflate', marshaller.encoding
    assert_equal large_payload, Marshal.load(Zlib::Inflate.inflate(result))
  end

  class HTTPHandle
    attr_accessor :read_timeout, :route_table

    def initialize
      reset
    end

    def respond_to(method, payload, code=200)
      klass = HTTPSuccess
      if code == 413
        klass = HTTPRequestEntityTooLarge
      elsif code == 415
        klass = HTTPUnsupportedMediaType
      elsif code >= 400
        klass = HTTPServerError
      end

      register(klass.new(Marshal.dump(payload), code)) do |request|
        request.path.include?(method.to_s) &&
          request.path.include?('marshal_format=ruby')
      end

      if NewRelic::LanguageSupport.using_version?('1.9')
        register(klass.new(JSON.dump(payload), code)) do |request|
          request.path.include?(method.to_s) &&
            request.path.include?('marshal_format=json')
        end
      end
    end

    def register(response, &block)
      @route_table[block] = response
    end

    def request(*args)
      @route_table.each_pair do |condition, response|
        if condition.call(args[0])
          return response
        end
      end
      HTTPNotFound.new('not found', 404)
    end

    def reset
      @route_table = {}
    end
  end

  module HTTPResponseMock
    attr_accessor :code, :body, :message, :headers

    def initialize(body, code=200, message='OK')
      @code = code
      @body = body
      @message = message
      @headers = {}
    end

    def [](key)
      @headers[key]
    end
  end
end
