require 'helper'
require 'chef/node'
require 'chef/run_status'

class Aws::FakeSNS
  attr_reader :sns_new

  def initialize(*_args)
    @sns_new = true
    self
  end

  def publish(*_args)
    true
  end

  def config
    @config ||= Seahorse::Client::Configuration.new
  end
end

class Chef::Handler::FakeSns < Chef::Handler::Sns
  def get_sns_subject
    sns_subject
  end

  def get_sns_body
    sns_body
  end
end

describe Chef::Handler::Sns do
  let(:data_dir) { ::File.join(::File.dirname(__FILE__), 'data') }
  let(:node) do
    node = Chef::Node.new
    node.name('test')
    node
  end
  let(:run_status) do
    run_status =
      if Gem.loaded_specs['chef'].version > Gem::Version.new('0.12.0')
        Chef::RunStatus.new(node, {})
      else
        Chef::RunStatus.new(node)
      end

    run_status.start_clock
    run_status.stop_clock
    run_status
  end
  let(:config) do
    {
      :access_key => '***AMAZON-KEY***',
      :secret_key => '***AMAZON-SECRET***',
      :topic_arn => 'arn:aws:sns:***'
    }
  end
  let(:sns_handler) { Chef::Handler::Sns.new(config) }
  let(:fake_sns) do
    Aws::FakeSNS.new(
      :access_key_id => config[:access_key],
      :secret_access_key => config[:secret_key],
      :region => config[:region],
      :logger => Chef::Log
    )
  end
  let(:fake_sns_handler) { Chef::Handler::FakeSns.new(config) }
  before do
    Aws::SNS::Client.stubs(:new).returns(fake_sns)

    Chef::Handler::Sns.any_instance.stubs(:node).returns(node)
    Chef::Handler::FakeSns.any_instance.stubs(:node).returns(node)
  end

  it 'should read the configuration options on initialization' do
    assert_equal config[:access_key], sns_handler.access_key
    assert_equal config[:secret_key], sns_handler.secret_key
  end

  it 'should be able to change configuration options using method calls' do
    sns_handler = Chef::Handler::Sns.new
    sns_handler.access_key(config[:access_key])
    sns_handler.secret_key(config[:secret_key])

    assert_equal config[:access_key], sns_handler.access_key
    assert_equal config[:secret_key], sns_handler.secret_key
  end

  it 'should try to send a SNS message when properly configured' do
    fake_sns.expects(:publish).once

    sns_handler.run_report_safely(run_status)
  end

  it 'should create a Aws::SNS object' do
    sns_handler.run_report_safely(run_status)

    assert_equal true, fake_sns.sns_new
  end

  it 'should get the AWS region from the ARN' do
    sns_handler = Chef::Handler::Sns.new
    sns_handler.topic_arn('arn:aws:sns:eu-west-1:1234:MyTopic')

    assert_equal 'eu-west-1', sns_handler.region
  end

  it 'should not detect AWS region automatically when manually set' do
    config[:region] = 'us-east-1'
    sns_handler = Chef::Handler::Sns.new(config)
    sns_handler.topic_arn('arn:aws:sns:eu-west-1:1234:MyTopic')
    sns_handler.run_report_safely(run_status)

    assert_equal 'us-east-1', sns_handler.region
  end

  it 'should be able to generate the default subject in chef-client' do
    Chef::Config[:solo] = false
    fake_sns_handler.run_report_unsafe(run_status)

    assert_equal 'Chef Client success in test', fake_sns_handler.get_sns_subject
  end

  it 'should be able to generate the default subject in chef-solo' do
    Chef::Config[:solo] = true
    fake_sns_handler.run_report_unsafe(run_status)

    assert_equal 'Chef Solo success in test', fake_sns_handler.get_sns_subject
  end

  it 'should use the configured subject when set' do
    config[:subject] = 'My Subject'
    fake_sns_handler.run_report_unsafe(run_status)

    assert_equal 'My Subject', fake_sns_handler.get_sns_subject
  end

  it 'should be able to generate the default message body' do
    fake_sns_handler.run_report_unsafe(run_status)

    fake_sns_handler.get_sns_body.must_match Regexp.new('Node Name: test')
  end

  it 'should throw an exception when the body template file does not exist' do
    config[:body_template] = '/tmp/nonexistent-template.erb'

    assert_raises(Chef::Exceptions::ValidationFailed) do
      sns_handler.run_report_unsafe(run_status)
    end
  end

  it 'should be able to generate the body template when configured as an '\
     'option' do
    body_msg = 'My Template'
    config[:body_template] = '/tmp/existing-template.erb'
    ::File.stubs(:exists?).with(config[:body_template]).returns(true)
    IO.stubs(:read).with(config[:body_template]).returns(body_msg)

    fake_sns_handler.run_report_unsafe(run_status)

    assert_equal body_msg, fake_sns_handler.get_sns_body
  end

  it 'should be able to read body templates in UTF-8' do
    config[:body_template] = ::File.join(data_dir, 'body_utf8.txt')

    fake_sns_handler.run_report_unsafe(run_status)

    assert_includes fake_sns_handler.get_sns_body, 'abc'
  end

  it 'should be able to read body templates in latin' do
    config[:body_template] = ::File.join(data_dir, 'body_latin.txt')

    fake_sns_handler.run_report_unsafe(run_status)

    assert_includes fake_sns_handler.get_sns_body, 'abc'
  end

  it 'should replace body characters with wrong encoding' do
    config[:body_template] = ::File.join(data_dir, 'body_latin.txt')

    fake_sns_handler.run_report_unsafe(run_status)

    assert_includes fake_sns_handler.get_sns_body, '???'
  end

  it 'should be able to use subject with wrong encoding' do
    config[:subject] = ::IO.read(::File.join(data_dir, 'subject_utf8.txt'))

    fake_sns_handler.run_report_unsafe(run_status)

    assert_includes fake_sns_handler.get_sns_subject, 'abc'
    assert_includes fake_sns_handler.get_sns_subject, 'xyz'
  end

  it 'should replace subject characters with wrong encoding' do
    config[:subject] = ::IO.read(::File.join(data_dir, 'subject_utf8.txt'))

    fake_sns_handler.run_report_unsafe(run_status)

    assert_includes fake_sns_handler.get_sns_subject, '???'
  end

  it 'should shorten long subjects' do
    config[:subject] = 'A' * 200

    fake_sns_handler.run_report_unsafe(run_status)

    assert_equal fake_sns_handler.get_sns_subject, 'A' * 100
  end

  it 'should publish messages if node["opsworks"]["activity"] does not exist' do
    fake_sns.expects(:publish).once

    sns_handler.run_report_safely(run_status)
  end

  it 'should publish messages if node["opsworks"]["activity"] matches allowed '\
     'acvities' do
    node.set['opsworks']['activity'] = 'deploy'
    config[:filter_opsworks_activity] = %w(deploy setup)

    fake_sns.expects(:publish).once
    sns_handler.run_report_safely(run_status)
  end

  it 'should not publish messages if node["opsworks"]["activity"] differs '\
     'from allowed acvities' do
    node.set['opsworks']['activity'] = 'configure'
    config[:filter_opsworks_activity] = %w(deploy setup)

    fake_sns.expects(:publish).never
    sns_handler.run_report_safely(run_status)
  end

  it 'should not publish messages if node["opsworks"]["activity"] is set, '\
     'but the node attribute is missing' do
    config[:filter_opsworks_activity] = %w(deploy setup)

    fake_sns.expects(:publish).never
    sns_handler.run_report_safely(run_status)
  end
end
