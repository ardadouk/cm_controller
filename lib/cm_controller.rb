require 'time'
require 'omf_rc'
require 'omf_common'
require 'yaml'
require 'open-uri'
require 'nokogiri'

$stdout.sync = true

@config = YAML.load_file('../etc/configuration.yaml')
@auth = @config[:auth]
@xmpp = @config[:xmpp]

module OmfRc::ResourceProxy::CMController
  include OmfRc::ResourceProxyDSL
  @timeout = 120

  register_proxy :cmController

  property :all_nodes, :default => []
  property :node_state

  hook :before_ready do |res|
    @config = YAML.load_file('../etc/configuration.yaml')
    @domain = @config[:domain]
    @nodes = @config[:nodes]
    puts "### nodes: #{@nodes}"
    @nodes.each do |node|
      tmp = {node_name: node[0], node_ip: node[1][:ip], node_mac: node[1][:mac], node_cm_ip: node[1][:cm_ip]}
      res.property.all_nodes << tmp
    end
  end

#   request :node_state do |res|
#     node = nil
#     puts "#### value is #{res.property.node_state}"
#     res.property.all_nodes.each do |n|
#       if n[:node_name] == res.property.node_state
#         node = n
#       end
#     end
#     puts "Node : #{node}"
#     ret = false
#     if node.nil?
#       puts "error: Node nill"
#       res.inform(:status, {
#         event_type: "EXIT",
#         exit_code: "-1",
#         node: value[:node],
#         msg: "Wrong node name."
#       }, :ALL)
#     else
#       ret = res.get_status(node)
#     end
#     ret
#   end

  configure :state do |res, value|
    node = nil
    res.property.all_nodes.each do |n|
      if n[:node_name] == value[:node].to_sym
        node = n
      end
    end
    puts "Node : #{node}"
    if node.nil?
      puts "error: Node nill"
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "-1",
        node: value[:node],
        msg: "Wrong node name."
      }, :ALL)
      return
    end

    case value[:status].to_sym
    when :on then res.start_node(node)
    when :off then res.stop_node(node)
    when :reset then res.reset_node(node)
    when :start_on_pxe then res.start_node_pxe(node)
    when :start_without_pxe then res.start_node_pxe_off(node, value[:last_action])
    when :get_status then res.status(node)
    else
      res.log_inform_warn "Cannot switch node to unknown state '#{value[:status].to_s}'!"
    end
  end

  work("wait_until_ping") do |res, ip|
    t = 0
    resp = false
    loop do
      sleep 2
      status = system("ping #{ip} -c 2 -w 2")
      if t < @timeout
        if status == true
          resp = true
          break
        end
      else
        resp = false
        break
      end
      t += 2
    end
    resp
  end

  work("wait_until_no_ping") do |res, ip|
    t = 0
    resp = false
    loop do
      sleep 2
      status = system("ping #{ip} -c 2 -w 2")
      if t < @timeout
        if status == false
          resp = true
          break
        end
      else
        resp = false
        break
      end
      t += 2
    end
    resp
  end

  work("get_status") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/status"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/status"))
    resp = doc.xpath("//Measurement//type//value").text.strip

    if resp == 'on'
      symlink_name = "/tftpboot/pxelinux.cfg/01-#{node[:node_mac]}"
      if File.exists?("#{symlink_name}")
        :on_pxe
      else
        :on
      end
    elsif resp == 'off'
      :off
    end
  end

  work('status') do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/status"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/status"))
    puts doc

    res.inform(:status, {
      event_type: "NODE_STATUS",
      exit_code: "0",
      node_name: "#{node[:node_name].to_s}",
      msg: "#{doc.xpath("//Measurement//type//value").text}"
    }, :ALL)
  end

  work("start_node") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/on"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/on"))
    puts doc
    res.inform(:status, {
      event_type: "START_NODE",
      exit_code: "0",
      node_name: "#{node[:node_name].to_s}",
      msg: "#{doc.xpath("//Response").text}"
    }, :ALL)

    if res.wait_until_ping(node[:node_ip])
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "0",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' is up."
      }, :ALL)
    else
      res.inform(:error, {
        event_type: "EXIT",
        exit_code: "-1",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' timed out while booting."
      }, :ALL)
    end
  end

  work("stop_node") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/off"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/off"))
    puts doc
    res.inform(:status, {
      event_type: "STOP_NODE",
      exit_code: "0",
      node_name: "#{node[:node_name].to_s}",
      msg: "#{doc.xpath("//Response").text}"
    }, :ALL)

    if res.wait_until_no_ping(node[:node_ip])
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "0",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' is down."
      }, :ALL)
    else
      res.inform(:error, {
        event_type: "EXIT",
        exit_code: "-1",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' timed out while shutting down."
      }, :ALL)
    end
  end

  work("reset_node") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/reset"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/reset"))
    puts doc
    res.inform(:status, {
      event_type: "RESET_NODE",
      exit_code: "0",
      node_name: "#{node[:node_name].to_s}",
      msg: "#{doc.xpath("//Response").text}"
    }, :ALL)

    if res.wait_until_ping(node[:node_ip])
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "0",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' is up after reset."
      }, :ALL)
    else
      res.inform(:error, {
        event_type: "EXIT",
        exit_code: "-1",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' timed out while reseting."
      }, :ALL)
    end
  end

  work("start_node_pxe") do |res, node|
    resp = res.get_status(node)
    if resp == :on
      symlink_name = "/tftpboot/pxelinux.cfg/01-#{node[:node_mac]}"
      if !File.exists?("#{symlink_name}")
        File.symlink("/tftpboot/pxelinux.cfg/omf-5.4", "#{symlink_name}")
      end
      puts "http://#{node[:node_cm_ip].to_s}/reset"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/reset"))
    elsif resp == :off
      symlink_name = "/tftpboot/pxelinux.cfg/01-#{node[:node_mac]}"
      if !File.exists?("#{symlink_name}")
        File.symlink("/tftpboot/pxelinux.cfg/omf-5.4", "#{symlink_name}")
      end
      puts "http://#{node[:node_cm_ip].to_s}/on"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/on"))
    elsif resp == :started_on_pxe
      puts "http://#{node[:node_cm_ip].to_s}/reset"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/reset"))
    end

    if res.wait_until_ping(node[:node_ip])
      res.inform(:status, {
        event_type: "PXE",
        exit_code: "0",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' is up on PXE."
      }, :ALL)
    else
      res.inform(:error, {
        event_type: "PXE",
        exit_code: "-1",
        node_name: "#{node[:node_name].to_s}",
        msg: "Node '#{node[:node_name].to_s}' timed out while trying to boot on PXE."
      }, :ALL)
    end
  end

  work("start_node_pxe_off") do |res, node, action|
    symlink_name = "/tftpboot/pxelinux.cfg/01-#{node[:node_mac]}"
    if File.exists?(symlink_name)
      File.delete(symlink_name)
    end
    if action == "reset"
      puts "http://#{node[:node_cm_ip].to_s}/reset"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/reset"))
      puts doc
      t = 0
      if res.wait_until_ping(node[:node_ip])
        res.inform(:status, {
          event_type: "PXE_OFF",
          exit_code: "0",
          node_name: "#{node[:node_name].to_s}",
          msg: "Node '#{node[:node_name].to_s}' is up."
        }, :ALL)
      else
        res.inform(:error, {
          event_type: "PXE_OFF",
          exit_code: "-1",
          node_name: "#{node[:node_name].to_s}",
          msg: "Node '#{node[:node_name].to_s}' timed out while booting."
        }, :ALL)
      end
    elsif action == "shutdown"
      puts "http://#{node[:node_cm_ip].to_s}/off"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/off"))
      puts doc
      if res.wait_until_no_ping(node[:node_ip])
        res.inform(:status, {
          event_type: "EXIT",
          exit_code: "0",
          node_name: "#{node[:node_name].to_s}",
          msg: "Node '#{node[:node_name].to_s}' is down."
        }, :ALL)
      else
        res.inform(:error, {
          event_type: "EXIT",
          exit_code: "-1",
          node_name: "#{node[:node_name].to_s}",
          msg: "Node '#{node[:node_name].to_s}' timed out while shutting down."
        }, :ALL)
      end
    end
  end
end


entity_cert = File.expand_path(@auth[:entity_cert])
entity_key = File.expand_path(@auth[:entity_key])
entity = OmfCommon::Auth::Certificate.create_from_x509(File.read(entity_cert), File.read(entity_key))

trusted_roots = File.expand_path(@auth[:root_cert_dir])

OmfCommon.init(:development, communication: { url: "xmpp://#{@xmpp[:username]}:#{@xmpp[:password]}@#{@xmpp[:server]}", auth: {} }) do
  OmfCommon.comm.on_connected do |comm|
    OmfCommon::Auth::CertificateStore.instance.register_default_certs(trusted_roots)
    OmfCommon::Auth::CertificateStore.instance.register(entity, OmfCommon.comm.local_topic.address)
    OmfCommon::Auth::CertificateStore.instance.register(entity)

    info "CMController >> Connected to XMPP server"
    cmContr = OmfRc::ResourceFactory.create(:cmController, { uid: 'cmController', certificate: entity })
    comm.on_interrupted { cmContr.disconnect }
  end
end
