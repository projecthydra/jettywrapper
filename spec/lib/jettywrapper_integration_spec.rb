require 'spec_helper'
require 'rubygems'
require 'uri'
require 'net/http'
require 'socket'

module Hydra
  describe Jettywrapper do    
    context "integration" do
      before(:all) do
        $stderr.reopen("/dev/null", "w")
      end
      
      it "starts" do
        jetty_params = {
          :jetty_home => File.expand_path("#{File.dirname(__FILE__)}/../../jetty"),
          :startup_wait => 30,
          :jetty_port => TEST_JETTY_PORTS.first
        }
        Jettywrapper.configure(jetty_params) 
        ts = Jettywrapper.instance
        ts.logger.debug "Stopping jetty from rspec."
        ts.stop
        ts.start      
        ts.logger.debug "Jetty started from rspec at #{ts.pid}"
        pid_from_file = File.open( ts.pid_path ) { |f| f.gets.to_i }
        ts.pid.should eql(pid_from_file)
      
        # Can we connect to solr?
        require 'net/http' 
        response = Net::HTTP.get_response(URI.parse("http://localhost:#{jetty_params[:jetty_port]}/solr/development/admin/"))
        response.code.should eql("200")
        ts.stop
      
      end
      
      it "won't start if it's already running" do
        jetty_params = {
          :jetty_home => File.expand_path("#{File.dirname(__FILE__)}/../../jetty"),
          :startup_wait => 30,
          :jetty_port => TEST_JETTY_PORTS.first
        }
        Jettywrapper.configure(jetty_params) 
        ts = Jettywrapper.instance
        ts.logger.debug "Stopping jetty from rspec."
        ts.stop
        ts.start
        ts.logger.debug "Jetty started from rspec at #{ts.pid}"
        response = Net::HTTP.get_response(URI.parse("http://localhost:#{jetty_params[:jetty_port]}/solr/development/admin/"))
        response.code.should eql("200")
        lambda { ts.start }.should raise_exception(/Server is already running/)
        ts.stop
      end
      
      it "can check to see whether a port is already in use" do
        jetty_params = {
          :jetty_home => File.expand_path("#{File.dirname(__FILE__)}/../../jetty"),
          :jetty_port => TEST_JETTY_PORTS.last,
          :startup_wait => 30
        }
        Jettywrapper.stop(jetty_params) 
        sleep 10
        Jettywrapper.is_port_in_use?(jetty_params[:jetty_port]).should eql(false)
        Jettywrapper.start(jetty_params) 
        Jettywrapper.is_port_in_use?(jetty_params[:jetty_port]).should eql(true)
        Jettywrapper.stop(jetty_params) 
      end
      
      it "raises an error if you try to start a jetty that is already running" do
        jetty_params = {
          :jetty_home => File.expand_path("#{File.dirname(__FILE__)}/../../jetty"),
          :jetty_port => TEST_JETTY_PORTS.first,
          :startup_wait => 30
        }
        ts = Jettywrapper.configure(jetty_params) 
        ts.stop
        ts.pid_file?.should eql(false)
        ts.start
        lambda{ ts.start }.should raise_exception
        ts.stop
      end

      it "raises an error if you try to start a jetty when the port is already in use" do
        jetty_params = {
          :jetty_home => File.expand_path("#{File.dirname(__FILE__)}/../../jetty"),
          :jetty_port => TEST_JETTY_PORTS.first,
          :startup_wait => 30
        }
	socket = TCPServer.new(TEST_JETTY_PORTS.first)
        begin
          ts = Jettywrapper.configure(jetty_params) 
          ts.stop
          ts.pid_file?.should eql(false)
          lambda{ ts.start }.should raise_exception
          ts.stop
        ensure
          socket.close
        end
      end

    end
  end
end
