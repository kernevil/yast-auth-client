# encoding: utf-8
# ------------------------------------------------------------------------------
# Copyright (c) 2016 SUSE LINUX GmbH, Nuernberg, Germany.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact SUSE Linux GmbH.
#
# ------------------------------------------------------------------------------
#
# Module: Manipulate system authentication configuration.
# Author: Howard Guo <hguo@suse.com>

require 'yast'
require 'resolv'
require 'open3'
require 'socket'
require 'tempfile'
require 'fileutils'
require 'date'

module Auth
    class AuthConf
        include Yast
        include I18n
        include Logger
        include UIShortcuts

        # Return network host name and environment facts.
        def self.get_net_facts
            resolvable_name = ''
            begin
                resolvable_name = Socket.gethostbyname(Socket.gethostname)
                resolvable_name = resolvable_name.fetch(0, '')
            rescue
                # Intentionally ignored
            end
            ip_addresses = []
            begin
                resolvable_ip = Socket.getaddrinfo(Socket.gethostname, nil)
                resolvable_ip = resolvable_ip.fetch(0, []).fetch(3, '')
                if resolvable_ip != ''
                    ip_addresses = [resolvable_ip]
                end
            rescue
                # Just get interface IPs
                ip_addresses = Socket.getifaddrs.select{|iface| iface.addr.ip?}.map{|iface| iface.addr.ip_address}.select{|addr| !addr.start_with?('127.')}
            end
            domain_name, status = Open3.capture2('domainname')
            if status.exitstatus != 0 || domain_name.strip == '(none)'
                domain_name = ''
            end
            domain_name.strip!
            facts = {
                'computer_name' => Socket.gethostname,
                'full_computer_name' => resolvable_name,
                'network_domain' => domain_name.chomp,
                'ip_addresses' => ip_addresses,
            }
            return facts
        end

        SSSDCapableNSSDatabases = ["passwd", "group", "sudoers", "automount"]
        LDAPCapableNSSDatabases = ["passwd", "group", "sudoers", "automount"]

        # Enable the specified NSS database.
        def nss_enable_module(db_name, module_name)
            names = Nsswitch.ReadDb(db_name)
            if !names.include?(module_name)
                Nsswitch.WriteDb(db_name, names + [module_name])
                Nsswitch.Write
            end
        end

        # Disable the specified NSS database.
        def nss_disable_module(db_name, module_name)
            names = Nsswitch.ReadDb(db_name)
            if names.include?(module_name)
                Nsswitch.WriteDb(db_name, names.select { |name| name != module_name })
                Nsswitch.Write
            end
        end

        # Enable and start the service.
        def service_enable_start(name)
            Service.Enable(name)
            if !(Service.Active(name) ? Service.Restart(name) : Service.Start(name))
                Report.Error(_('Failed to start service %s. Please use system journal (journalctl -n -u %s) to diagnose.') % [name, name])
            end
        end

        # Disable and stop the service.
        def service_disable_stop(name)
            Service.Disable(name)
            if Service.Active(name) && !Service.Stop(name)
                Report.Error(_('Failed to stop service %s. Please use system journal (journalctl -n -u %s) to diagnose.') % [name, name])
            end
        end

        # Adjust PAM settings to make sure:
        # - Any of enabled unix/krb/ldap/sss mechanisms can fullfill user authentication.
        # - Local accounts are sufficient to be accounts.
        # This is a scary and security critical function, be extra careful with changes.
        def fix_pam
            sufficient_auth = ['pam_unix.so', 'pam_sss.so', 'pam_ldap.so', 'pam_krb5.so']
            lines = IO.readlines('/etc/pam.d/common-auth')
            auth = File.open('/etc/pam.d/common-auth', 'w+', 0600)
            lines.each { |line|
                columns = line.split(/\s+/)
                if /\s*#/.match(line)
                    # Write down the comment
                    auth.write(line)
                else
                    if columns.length >= 3 && columns[2] != 'pam_deny.so'
                        if sufficient_auth.include?(columns[2])
                            # Mark the module "sufficient"
                            columns[1] = 'sufficient'
                            auth.write(columns.join('    ') + "\n")
                        else
                            # Write down the module as-is
                            auth.write(line)
                        end
                    else
                        # Too few columns, just write it down.
                        auth.write(line)
                    end
                end
            }
            # Eventually deny all access if no sufficient module is satisfied
            # Bad luck for smart card users, this Yast module will not support that scenario.
            auth.write("auth    required    pam_deny.so\n")
            auth.close

            # For accounts, make it sufficient to match local account.
            lines = IO.readlines('/etc/pam.d/common-account')
            account = File.open('/etc/pam.d/common-account', 'w+', 0600)
            lines.each { |line|
                columns = line.split(/\s+/)
                if !/\s*#/.match(line) && columns.length >= 3
                    if columns[2] == 'pam_unix.so'
                        account.write(columns.join('    ') + "\n")
                        account.write("account    sufficient    pam_localuser.so\n")
                    elsif columns[2] != 'pam_localuser.so'
                       # exclude existing line about pam_localuser
                       account.write(line)
                    end
                else
                    account.write(line)
                end
            }
            account.close
        end

        # Clear all configuration objects.
        def clear
            # Kerberos configuration
            @krb_conf = {'include' => [], 'libdefaults' => {}, 'realms' => {}, 'domain_realms' => {}, 'logging' => {}}
            @krb_pam = false
            # LDAP configuration (/etc/ldap.conf)
            @ldap_conf = {}
            @ldap_pam = false
            @ldap_nss = []
            # SSSD configuration (/etc/sssd/sssd.conf)
            @sssd_conf = {}
            @sssd_pam = false
            @sssd_nss = []
            @sssd_enabled = false
            # Make the basic SSSD configuration structure
            sssd_lint_conf
            # Auxialiry daemons and mkhomedir
            # If you call aux_apply, autofs will be enabled if any of the following condition is met:
            # - autofs_enabled == true
            # - SSSD is providing automount
            # - LDAP is providing automount
            @autofs_enabled = false
            @nscd_enabled = false
            @mkhomedir_pam = false
            # AD enrollment details
            @ad_domain = ''
            @ad_user = ''
            @ad_ou = ''
            @ad_pass = ''
            @ad_overwrite_smb_conf = false
        end

        def initialize
            Yast.import "Nsswitch"
            Yast.import "Pam"
            Yast.import "Service"
            Yast.import "Package"
            clear
            # AutoYast editor mode prevents changes from being applied
            @autoyast_editor_mode = false
            # Hold 'modified' flag for autoyast
            @autoyast_modified = false
        end

        # Load SSSD configuration.
        def sssd_read
            @sssd_conf = {}
            # Destruct sssd.conf file
            SCR.UnmountAgent(path('.etc.sssd_conf'))
            SCR.Read(path('.etc.sssd_conf.all')).fetch('value', []).each { |sect|
                if sect['kind'] == 'section'
                    sect_name = sect['name'].strip
                    sect_elems = sect['value']
                    sect_vals_array = sect_elems.select { |elem| elem['kind'] == 'value' }.map { |elem| [elem['name'].strip, elem['value'].strip] }
                    sect_vals = Hash[*(sect_vals_array.flatten)]
                    @sssd_conf[sect_name] = sect_vals
                end
            }
            # Read PAM/NSS/daemon status
            @sssd_pam = Pam.Enabled('sss')
            @sssd_nss = []
            SSSDCapableNSSDatabases.each { |name|
                if Nsswitch.ReadDb(name).any? { |db| db == 'sss' }
                    @sssd_nss += [name]
                end
            }
            @sssd_enabled = Service.Enabled('sssd')
            sssd_lint_conf
        end

        
        # Enable an SSSD service, if it has not yet been enabled.
        def sssd_enable_svc(svc_name)
            @sssd_conf['sssd']['services'] += [svc_name] if !@sssd_conf['sssd']['services'].include?(svc_name)
            if ['pam', 'nss', 'autofs', 'ssh', 'sudo', 'pac'].include?(svc_name)
                # Create a section for these services
                @sssd_conf[svc_name] = {} if !@sssd_conf[svc_name]
            end
        end

        # Disable an SSSD service. It does not remove the service configuration.
        def sssd_disable_svc(svc_name)
            @sssd_conf['sssd']['services'] -= [svc_name]
        end

        # Make sure that at least the SSSD skeleton configuration is present, and fix PAM/NSS sections if they are missing.
        def sssd_lint_conf
            # Fix [sssd]
            if !@sssd_conf['sssd']
                @sssd_conf['sssd'] = {}
            end
            # Config file version is always 2 - there can be no exception
            @sssd_conf['sssd']['config_file_version'] = '2'
            sssd_services = @sssd_conf['sssd']['services']
            if !sssd_services
                @sssd_conf['sssd']['services'] = []
            end
            if sssd_services && (sssd_services.kind_of?(::String))
                @sssd_conf['sssd']['services'] = sssd_services.split(%r{\s*,\s*})
            end
            sssd_domains = @sssd_conf['sssd']['domains']
            if !sssd_domains
                 @sssd_conf['sssd']['domains'] = []
            end
            if sssd_domains && sssd_domains.kind_of?(::String)
                @sssd_conf['sssd']['domains'] = sssd_domains.split(%r{\s*,\s*})
            end
        end

        # Return SSSD configuration.
        def sssd_export
            return {'conf' => @sssd_conf, 'pam' => @sssd_pam, 'nss' => @sssd_nss, 'enabled' => @sssd_enabled}
        end

        # Set configuration for SSSD from exported objects.
        def sssd_import(exported_conf)
            @sssd_conf = exported_conf['conf']
            @sssd_pam = exported_conf['pam']
            @sssd_nss = exported_conf['nss']
            @sssd_enabled = exported_conf['enabled']
        end

        # Generate sssd.conf content from the current configuration.
        def sssd_make_conf
            sssd_lint_conf
            content = ''
            @sssd_conf.each { |sect_name, conf|
                content += "[#{sect_name}]\n"
                if conf
                    conf.each { |key, value|
                        str_value = value.to_s
                        if str_value != ''
                            # Join arrays
                            if value.kind_of?(Array)
                                str_value = value.join(',')
                            end
                            content += "#{key} = #{str_value}\n"
                        end
                    }
                end
                content += "\n"
            }
            return content
        end

        # Return name of all services that should be enabled in [sssd] services parameter.
        def sssd_get_services
            svcs = []
            svcs += ['pam'] if @sssd_pam
            svcs += ['nss'] if @sssd_nss.any?
            svcs += ['autofs'] if @sssd_nss.include?('automount')
            svcs += ['sudo'] if @sssd_nss.include?('sudoers')
            return svcs
        end

        # Return name of all domains (without domain/ prefix) that are configured.
        def sssd_get_domains
            @sssd_conf.keys.select { |key| key.start_with?('domain/') }.map{ |sect_name| sect_name.sub('domain/', '') }
        end

        # Return name of all domains (without domain/ prefix) that are not enabled in [sssd] domains parameter.
        def sssd_get_inactive_domains
            return sssd_get_domains - @sssd_conf['sssd']['domains']
        end

        # Remove all cached data by removing all files from /var/lib/sss/db
        def sssd_clear_cache
            was_active = false
            if Service.Active('sssd')
                was_active = true
                Service.Stop('sssd')
            end
            Dir.glob('/var/lib/sss/db/*').each{ |f| File.unlink(f)}
            if was_active
                Service.Start('sssd')
            end
        end

        # Immediately apply SSSD configuration, including PAM/NSS/daemon configuration.
        def sssd_apply
            if @autoyast_editor_mode
                return
            end
            sssd_lint_conf
            # Calculate package requirements
            pkgs = []
            if @sssd_enabled || @sssd_pam || @sssd_nss.any?
                pkgs += ['sssd']
                # Only install the required provider packages. By convention, they are named 'sssd-*'.
                domain_providers = ['ad', 'ldap', 'ipa', 'proxy', 'krb5']
                @sssd_conf.each { |sect_name, conf|
                    id_provider = conf['id_provider']
                    auth_provider = conf['auth_provider']
                    if domain_providers.include?(id_provider)
                        pkgs += ['sssd-' + id_provider]
                    end
                    if domain_providers.include?(id_provider)
                        pkgs += ['sssd-' + id_provider]
                    end
                }
            end
            pkgs.delete_if { |name| Package.Installed(name) }
            if pkgs.any?
                if !Package.DoInstall(pkgs)
                    Report.Error(_('Failed to install software packages required for running SSSD.'))
                end
            end
            # Write SSSD config file and correct its permission and ownerships
            sssd_conf = File.new('/etc/sssd/sssd.conf', 'w')
            sssd_conf.chmod(0600)
            sssd_conf.chown(0, 0)
            sssd_conf.write(sssd_make_conf)
            sssd_conf.close
            # Save PAM/NSS/daemon status
            if @sssd_pam
                Pam.Add('sss')
            else
                Pam.Remove('sss')
            end
            fix_pam
            SSSDCapableNSSDatabases.each { |db| nss_disable_module(db, 'sss') }
            if @sssd_nss.any?
                @sssd_nss.each { |db|
                    nss_enable_module(db, 'sss')
                }
            end
            if @sssd_enabled
                sssd_clear_cache
                service_enable_start('sssd')
            else
                service_disable_stop('sssd')
            end
        end

        # Load LDAP configuration.
        def ldap_read
            @ldap_conf = {}
            # Destruct ldap.conf file
            SCR.UnmountAgent(path('.etc.ldap_conf'))
            SCR.Read(path('.etc.ldap_conf.all')).fetch('value', []).each { |entry|
                if entry['kind'] == 'value'
                    entry_name = entry['name'].strip
                    entry_value = entry['value'].strip
                    # Store values from duplicate keys in the original order
                    existing_value = @ldap_conf[entry_name]
                    if existing_value && existing_value.kind_of?(::String)
                        @ldap_conf[entry_name] = [existing_value, entry_value]
                    elsif existing_value && existing_value.kind_of?(::Array)
                        @ldap_conf[entry_name] = existing_value + [entry_value]
                    else
                        @ldap_conf[entry_name] = entry_value
                    end
                end
            }
            # Read PAM/NSS
            @ldap_pam = Pam.Enabled('ldap')
            @ldap_nss = []
            LDAPCapableNSSDatabases.each { |name|
                if Nsswitch.ReadDb(name).any? { |db| db == 'ldap' }
                    @ldap_nss += [name]
                end
            }
        end

        # Return LDAP configuration.
        def ldap_export
            return {'conf' => @ldap_conf, 'pam' => @ldap_pam, 'nss' => @ldap_nss}
        end

        # Set configuration for LDAP from exported objects.
        def ldap_import(exported_conf)
            @ldap_conf = exported_conf['conf']
            @ldap_pam = exported_conf['pam']
            @ldap_nss = exported_conf['nss']
        end

        # Generate ldap.conf content from the current configuration.
        def ldap_make_conf
            content = ''
            @ldap_conf.each { |key, value|
                if value.kind_of?(Array)
                    value.each { |v|
                        if v.to_s != ''
                            content += "#{key} #{v.to_s}\n"
                        end
                    }
                elsif value.to_s != ''
                    content += "#{key} #{value.to_s}\n"
                end
            }
            return content
            return @ldap_conf.map{ |tuple2| "#{tuple2[0]} #{}" }.join("\n")
        end

        # Immediately apply LDAP configuration, including PAM/NSS configuration.
        def ldap_apply
            if @autoyast_editor_mode
                return
            end
            # Calculate package requirements
            pkgs = []
            if @ldap_pam
                pkgs += ['pam_ldap']
            end
            if @ldap_nss
                pkgs += ['nss_ldap']
                if @ldap_nss.include?('automount')
                    pkgs += ['openldap2-client'] # provides /etc/openldap/ldap.conf
                end
            end
            pkgs.delete_if { |name| Package.Installed(name) }
            if pkgs.any?
                if !Package.DoInstall(pkgs)
                    Report.Error(_('Failed to install software packages required for LDAP.'))
                end
            end
            # Write LDAP config file and correct its permission and ownerships
            ldap_conf = File.new('/etc/ldap.conf', 'w')
            ldap_conf.chmod(644)
            ldap_conf.chown(0, 0)
            ldap_conf.write(ldap_make_conf)
            ldap_conf.close
            # If automount is enabled, overwrite openldap's ldap.conf as well.
            if @ldap_nss.include?('automount')
                ldap_conf = File.new('/etc/openldap/ldap.conf', 'w')
                ldap_conf.chmod(644)
                ldap_conf.chown(0, 0)
                ldap_conf.write(ldap_make_conf)
                ldap_conf.close
            end
            # Save PAM/NSS/daemon status
            if @ldap_pam
                Pam.Add('ldap')
            else
                Pam.Remove('ldap')
            end
            fix_pam
            LDAPCapableNSSDatabases.each { |db| nss_disable_module(db, 'ldap') }
            if @ldap_nss.any?
                @ldap_nss.each { |db| nss_enable_module(db, 'ldap') }
            end
        end

        # Run ldapsearch to test the parameters. Return empty string if test is successful, otherwise return ldapsearch error output.
        def ldap_test_bind(uri, start_tls, dn, password, base_dn)
            # Make sure openldap client is installed
            if !Package.Installed('openldap2-client')
                if !Package.DoInstall(['openldap2-client'])
                    return 'Failed to install openldap2-client package'
                end
            end
            # Create a temporary file to hold the password
            pwd_filename = "yastauthclient-ldaptestbind-#{Time.now.strftime('%Y%m%d%I%M%S')}"
            pwd_file = File.open(pwd_filename, 'w', 0600)
            pwd_file.write(password)
            pwd_file.close
            # Run ldapsearch with password bind
            cmd = "ldapsearch -o nettimeout=5 -s one -x -H '#{uri}' "
            if start_tls
                cmd += '-ZZ '
            end
            if dn.to_s != ''
                cmd += "-D '#{dn}' -y '#{pwd_filename}' "
            end
            cmd += "-b #{base_dn}"
            out = ''
            errout = ''
            exitstatus = 0
            Open3.popen3(cmd){ |stdin, stdout, stderr, control|
                stdin.close
                out = stdout.read
                errout = stderr.read
                exitstatus = control.value
            }
            File.unlink(pwd_file)
            if exitstatus == 0
                return ''
            end
            return "#{_('ERROR: ')} #{out}\n#{errout}"
        end

        # Load Kerberos configuration sections from the input text.
        def krb_parse(krb_conf_text)
            long_attr1 = ''
            long_attr2 = ''
            sect = ''
            new_krb_conf = {'include' => [], 'libdefaults' => {}, 'realms' => {}, 'domain_realms' => {}, 'logging' => {}}
            # Break down sections and key-value pairs
            krb_conf_text.split(/\n/).each{ |line|
                # Throw away comment
                comment_match = /^\s*[#;].*$/.match(line)
                if comment_match
                    next
                end
                # Remember include/includedir directives
                include_match = /^(includedir|include|module)\s+(.+)$/.match(line)
                if include_match
                    new_krb_conf['include'] += ["#{include_match[1]} #{include_match[2]}"]
                    next
                end
                # Remember section name
                sect_match = /^\[([.a-zA-Z0-9_-]+)\]\s*$/.match(line)
                if sect_match
                    # remember current section
                    sect = sect_match[1]
                    next
                end
                # Remember expanded attribute
                long_attr_match = /^\s*([.a-zA-Z0-9_-]+)\s*=\s*{\s*$/.match(line)
                if long_attr_match
                    if long_attr1 == ''
                        long_attr1 = long_attr_match[1]
                    elsif long_attr2 == ''
                        long_attr2 = long_attr_match[1]
                    end
                    next
                end
                # Closing an expanded attribute
                close_long_attr_match = /^\s*}\s*$/.match(line)
                if close_long_attr_match
                    if !new_krb_conf[sect]
                        new_krb_conf[sect] = {}
                    end
                    sect_conf = new_krb_conf[sect]
                    if long_attr1 != ''
                        if !sect_conf[long_attr1]
                            sect_conf[long_attr1] = {}
                        end
                        sect_conf = sect_conf[long_attr1]
                    end
                    if long_attr2 != ''
                        long_attr2 = ''
                    elsif long_attr1 != ''
                        long_attr1 = ''
                    end
                    next
                end
                # Note down key-value pairs in the current section
                kv_match = /^\s*([.a-zA-Z0-9_-]+)\s*=\s*([^{}]+)\s*$/.match(line)
                if kv_match
                    if !new_krb_conf[sect]
                        new_krb_conf[sect] = {}
                    end
                    sect_conf = new_krb_conf[sect]
                    if long_attr1 != ''
                        if !sect_conf[long_attr1]
                            sect_conf[long_attr1] = {}
                        end
                        sect_conf = sect_conf[long_attr1]
                    end
                    if long_attr2 != ''
                        if !sect_conf[long_attr2]
                            sect_conf[long_attr2] = {}
                        end
                        sect_conf = sect_conf[long_attr2]
                    end
                    key = kv_match[1]
                    val = kv_match[2]
                    # A key can hold an array of values
                    existing_value = sect_conf[key]
                    if existing_value && existing_value.kind_of?(::String)
                        sect_conf[key] = [existing_value, val]
                    elsif existing_value && existing_value.kind_of?(::Array)
                        sect_conf[key] = existing_value + [val]
                    else
                        sect_conf[key] = val
                    end
                    next
                end
                # Note down single value
                key = ''
                v_match = /^\s*([^{}\n\r]+)\s*$/.match(line)
                if v_match && long_attr1 != nil
                    if !new_krb_conf[sect]
                        new_krb_conf[sect] = {}
                    end
                    sect_conf = new_krb_conf[sect]
                    if long_attr1 != ''
                        key = long_attr1
                    end
                    if long_attr2 != ''
                        # long_attr2 is a key under long_attr1
                        if !sect_conf[long_attr1]
                            sect_conf[long_attr1] = {}
                        end
                        sect_conf = sect_conf[long_attr1]
                        key = long_attr2
                    end
                    val = v_match[1]
                    # A key can hold an array of values
                    existing_value = sect_conf[key]
                    if existing_value && existing_value.kind_of?(::String)
                        sect_conf[key] = [existing_value, val]
                    elsif existing_value && existing_value.kind_of?(::Array)
                        sect_conf[key] = existing_value + [val]
                    else
                        sect_conf[key] = val
                    end
                    next
                end
            }
            # These two realm attributes must be placed inside an array
            new_krb_conf['realms'].each {|_, conf|
                ['kdc', 'auth_to_local'].each { |attr|
                    if conf[attr].kind_of?(::String)
                        conf[attr] = [conf[attr]]
                    end
                }
            }
            @krb_conf = new_krb_conf
        end

        # Load Kerberos PAM status, and configuration sections from /etc/krb5.conf.
        def krb_read
            # Parse krb5.conf file
            begin
                conf_file = File.new('/etc/krb5.conf')
                content = conf_file.read
            rescue
                # Intentionally ignore error
            ensure
                if conf_file != nil
                    conf_file.close
                end
                if content == nil
                    content = ''
                end
            end
            krb_parse(content)

            # Read PAM
            @krb_pam = Pam.Enabled('krb5')
        end

        # Follow the specified path that leads to a key in the configuration structure,
        # if the path eventually leads to a nil value, the default is returned.
        # Otherwise, the value is returned.
        def krb_conf_get(keys, default)
            copy_keys = keys
            key = ''
            val = @krb_conf
            copy_keys.each { |key|
                if val == nil
                    break
                end
                val = val[key]
            }
            if val == nil
                return default
            else
                return val
            end
        end

        # Follow the specified path that leads to a key in the configuration structure,
        # return true only if it is set and the value is either 'yes' or 'true'.
        # If the key does not exist, the default value is returned.
        def krb_conf_get_bool(keys, default)
            val = krb_conf_get(keys, nil)
            if val == nil
                return default
            elsif val == true || val == false
                return val
            else
                return val.downcase == 'yes' || val.downcase == 'true'
            end
        end

        # Return LDAP configuration.
        def krb_export
            return {'conf' => @krb_conf, 'pam' => @krb_pam}
        end

        # Set configuration for Kerberos from exported objects.
        def krb_import(exported_conf)
            @krb_conf = exported_conf['conf']
            @krb_pam = exported_conf['pam']
        end

        def krb_make_sect_conf(sect_conf, num_indent)
            if !sect_conf
                return ''
            end
            content = ''
            sect_conf.each { |key, value|
                if value.kind_of?(::Array)
                    if value.length > 0
                        if key == 'auth_to_local'
                            if value.length == 1
                                # A single auth_to_local value must not be in an array
                                content += "#{' ' * num_indent}#{key} = #{value[0].to_s}\n"
                            else
                                # Expand auth_to_local array into {}
                                content += "#{' ' * num_indent}#{key} = {\n"
                                value.each { |val|
                                    if val.to_s != ''
                                        content += "#{' ' * num_indent}    #{val.to_s}\n"
                                    end
                                }
                                content += "#{' ' * num_indent}}\n"
                            end
                        else
                            # Expand array into multiple key-value pairs
                            value.each { |val|
                                if val.to_s != ''
                                    content += "#{' ' * num_indent}#{key} = #{val.to_s}\n"
                                end
                            }
                        end
                    end
                elsif value.kind_of?(::Hash)
                    if value.length > 0
                        # Expand hash into {}
                        content += "#{' ' * num_indent}#{key} = {\n"
                        value.each { |key, val|
                            if val.to_s != ''
                                content += "#{' ' * num_indent}    #{key} = #{val.to_s}\n"
                            end
                        }
                        content += "#{' ' * num_indent}}\n"
                    end
                elsif value.to_s != ''
                    content += "#{' ' * num_indent}#{key} = #{value.to_s}\n"
                end
            }
            return content
        end
        # Generate krb5.conf content from the current configuration.
        def krb_make_conf
            # Write down includes first
            content = @krb_conf['include'].join("\n") + "\n\n"
            # In the first pass do not make text content for [realms]
            @krb_conf.each { |sect_name, sect_conf|
                if sect_name != 'realms' && sect_name != 'include'
                    content += "[#{sect_name}]\n"
                    if sect_conf
                        content += krb_make_sect_conf(sect_conf, 4)
                    end
                    content += "\n"
                end
            }
            # Make text content for [realms]
            content += "[realms]\n"
            @krb_conf['realms'].each { |realm_name, sect_conf|
                content += "    #{realm_name} = {\n"
                content += krb_make_sect_conf(sect_conf, 8)
                content += "    }\n"
            }
            return content
        end

        # Immediately apply Kerberos configuration, including PAM configuration.
        def krb_apply
            if @autoyast_editor_mode
                return
            end
            # Calculate package requirements
            pkgs = []
            if @krb_pam
                pkgs += ['pam_krb5', 'krb5', 'krb5-client']
            end
            pkgs.delete_if { |name| Package.Installed(name) }
            if pkgs.any?
                if !Package.DoInstall(pkgs)
                    Report.Error(_('Failed to install software packages required for Kerberos.'))
                end
            end
            # Write LDAP config file and correct its permission and ownerships
            krb_conf = File.new('/etc/krb5.conf', 'w')
            krb_conf.chmod(0644)
            krb_conf.chown(0, 0)
            krb_conf.write(krb_make_conf)
            krb_conf.close
            # Save PAM/NSS/daemon status
            if @krb_pam
                Pam.Add('krb5')
            else
                Pam.Remove('krb5')
            end
            fix_pam
        end
        
        # Create a Kerberos realm if it does not yet exist. If it already exists, update the configuration. All parameters are required.
        def krb_add_update_realm(realm_name, kdc_addr, admin_addr, make_domain_realms, make_default)
            realm_name = realm_name.upcase.strip
            if !@krb_conf['realms'][realm_name]
                @krb_conf['realms'][realm_name] = {}
            end
            @krb_conf['realms'][realm_name].merge!({"kdc" => kdc_addr, "admin_server" => admin_addr})
            if make_domain_realms
                @krb_conf['domain_realms'].merge!({".#{realm_name.downcase}" => realm_name, "#{realm_name.downcase}" => realm_name})
            else
                @krb_conf['domain_realms'].delete(".#{realm_name.downcase}")
                @krb_conf['domain_realms'].delete("#{realm_name.downcase}")
            end
            if make_default || @krb_conf['libdefaults']['default_realm'].to_s == ''
                @krb_conf['libdefaults']['default_realm'] = realm_name
            end
        end

        # Load auxiliary daemon/PAM configuration.
        def aux_read
            @autofs_enabled = Service.Enabled('autofs')
            @nscd_enabled = Service.Enabled('nscd')
            @mkhomedir_pam = Pam.Enabled('mkhomedir')
        end

        # Return auxiliary daemon configuration.
        def aux_export
            return {'autofs' => @autofs_enabled, 'nscd' => @nscd_enabled, 'mkhomedir' => @mkhomedir_pam}
        end

        # Set configuration for auxiliary daemons/PAM from exported objects.
        def aux_import(exported_conf)
            @autofs_enabled = exported_conf['autofs']
            @nscd_enabled = exported_conf['nscd']
            @mkhomedir_pam = exported_conf['mkhomedir']
        end

        # Immediately enable(start)/disable(stop) the auxiliary daemons.
        def aux_apply
            if @autoyast_editor_mode
                return
            end
            # Install required packages
            pkgs = []
            if @autofs_enabled || @sssd_nss.include?('automount') || @ldap_nss.include?('automount')
                pkgs += ['autofs']
            end
            if @nscd_enabled
                pkgs += ['nscd']
            end
            pkgs.delete_if { |name| Package.Installed(name) }
            if pkgs.any?
                if !Package.DoInstall(pkgs)
                    Report.Error(_('Failed to install software packages required by autofs/nscd daemons.'))
                end
            end
            # Enable/disable mkhomedir
            if @mkhomedir_pam
                Pam.Add('mkhomedir')
            else
                Pam.Remove('mkhomedir')
            end
            fix_pam
            # Start/stop daemons
            if @autofs_enabled || @sssd_nss.include?('automount') || @ldap_nss.include?('automount')
                service_enable_start('autofs')
            else
                service_disable_stop('autofs')
            end
            if @nscd_enabled
                service_enable_start('nscd')
            else
                service_disable_stop('nscd')
            end
        end
        
        # Create a temporary file holding smb.conf for the specified AD domain. Return absolute path to the temporary file.
        def ad_create_tmp_smb_conf(ad_domain_name, workgroup_name)
            out = Tempfile.new("tempfile")
            out.write("
[global]
    security = ads
    realm = #{ad_domain_name}
    workgroup = #{workgroup_name}
    log file = /var/log/samba/%m.log
    kerberos method = secrets and keytab
    client signing = yes
    client use spnego = yes
")
            out.close
            return out
        end

        # Call package installer to install Samba if it has not yet been installed.
        def ad_install_samba
            if Package.Installed('samba') || Package.DoInstall(['samba'])
                return true
            end
            Report.Error(_('Failed to install Samba, required by Active Directory operations.'))
            return false
        end

        # Return workgroup name of the given AD domain, return empty string if there is an error.
        def ad_get_workgroup_name(ad_host_or_domain)
            if !ad_install_samba
                return ''
            end
            out, status = Open3.capture2("net ads lookup -S #{ad_host_or_domain}")
            if status.exitstatus != 0
                return ''
            end
            # Look for pre-win2k domain (i.e. workgroup) among the key-value output
            workgroup_name = ''
            out.split("\n").each { |line|
                fields = line.split(':')
                if fields[0] && fields[0].strip.downcase == 'pre-win2k domain'
                    workgroup_name = fields[1].strip
                end
            }
            return workgroup_name
        end

        # Return a tuple of two booleans: AD has this computer entry or not, Kerberos has the appropriate keytab or not.
        def ad_get_membership_status(ad_domain_name)
            if !ad_install_samba
                return [false, false]
            end
            smb_conf = ad_create_tmp_smb_conf(ad_domain_name, ad_get_workgroup_name(ad_domain_name))
            _, status = Open3.capture2("net -s #{smb_conf.path} ads testjoin")

            ad_has_computer = status.exitstatus == 0
            klist, status = Open3.capture2("klist -k")
            kerberos_has_key = klist.split("\n").any?{ |line| /#{Socket.gethostname}.*#{ad_domain_name.downcase}/.match(line.downcase) }

            smb_conf.unlink
            return [ad_has_computer, kerberos_has_key]
        end

        # Memorise AD enrollment parameters.
        def ad_set_enrollment_params(domain_name, username, slash_delimited_orgunit, password)
            @ad_domain = ad_domain_name
            @ad_user = username
            @ad_ou = slash_delimited_orgunit
            @ad_pass = password
        end

        # Return AD enrollment configuration.
        def ad_export
            return {'domain' => @ad_domain, 'user' => @ad_user, 'ou' => @ad_ou, 'pass' => @ad_pass, 'overwrite_smb_conf' => @ad_overwrite_smb_conf}
        end

        # Set configuration for AD enrollment from exported objects.
        def ad_import(exported_conf)
            @ad_domain = exported_conf['domain']
            @ad_user = exported_conf['user']
            @ad_ou = exported_conf['ou']
            @ad_pass= exported_conf['pass']
            @ad_overwrite_smb_conf = exported_conf['overwrite_smb_conf']
        end

        # Run "net ads join". Return tuple of boolean success status and command output.
        # Kerberos configuration must have been read before calling this function.
        # Kerberos configuration will be written.
        def ad_join_domain
            if @autoyast_editor_mode || @ad_domain.to_s == '' || @ad_user.to_s == '' || @ad_pass.to_s == ''
                return [true, _('Nothing is done because AD is not configured')]
            end
            # Configure Kerberos
            kdc_host_name = ad_find_kdc(@ad_domain)
            if kdc_host_name == ''
                return [false, _("Cannot locate Active Directory's Kerberos via DNS lookup.\n" +
                                "Please configure your network environment to use AD server as the name resolver.")]
            end
            krb_add_update_realm(@ad_domain.upcase, kdc_host_name, kdc_host_name, true, false)
            krb_apply

            # Create a temporary smb.conf to join this computer
            if !ad_install_samba
                return [false, _('Failed to install Samba')]
            end
            smb_conf = ad_create_tmp_smb_conf(@ad_domain, ad_get_workgroup_name(@ad_domain))
            output = ''
            exitstatus = 0
            ou_param = @ad_ou == '' ? '' : "createcomputer=#{@ad_ou}"

            Open3.popen2("net -s #{smb_conf.path} ads join #{ou_param} -U #{@ad_user}"){ |stdin, stdout, control|
                stdin.print(@ad_pass + "\n")
                stdin.close
                output = stdout.read
                exitstatus = control.value
            }

            # Get rid of the first output line that says "Enter XXX password"
            output = output.split("\n").drop(1).join("\n")
            # Optionally back up and save new samba configuration
            if @ad_save_smb_conf
                path_original_smb_conf = '/etc/samba/smb.conf'
                if File.exists?(path_original_smb_conf)
                    ::FileUtils.copy_file(path_original_smb_conf, "#{path_original_smb_conf}.bak.#{Time.now.strftime('%Y%m%d%I%M%S')}", true, false)
                end
                ::FileUtils.copy_file(smb_conf.path, path_original_smb_conf, true, false)
            end
            smb_conf.unlink
            return [exitstatus == 0, output]
        end

        # Return the PDC host name of the given AD domain via DNS lookup. If it cannot be found, return an empty string.
        def ad_find_pdc(ad_domain_name)
            begin
                return Resolv::DNS.new.getresource("_ldap._tcp.pdc._msdcs.#{ad_domain_name}", Resolv::DNS::Resource::IN::SRV).target.to_s
            rescue Resolv::ResolvError
                return ''
            end
        end

        # Return the KDC host name of the given AD domain via DNS lookup. If it cannot be found, return an empty string.
        def ad_find_kdc(ad_domain_name)
            begin
                return Resolv::DNS.new.getresource("_kerberos._tcp.dc._msdcs.#{ad_domain_name}", Resolv::DNS::Resource::IN::SRV).target.to_s
            rescue Resolv::ResolvError
                return ''
            end
        end

        # Return list of package names that should be installed to satisfy all configuration requirements.
        def calc_pkg_deps
            pkgs = []
            if @sssd_enabled || @sssd_pam || @sssd_nss.any?
                pkgs += ['sssd']
                # Only install the required provider packages. By convention, they are named 'sssd-*'.
                domain_providers = ['ad', 'ldap', 'ipa', 'proxy', 'krb5']
                @sssd_conf.each { |sect_name, conf|
                    id_provider = conf['id_provider']
                    auth_provider = conf['auth_provider']
                    if domain_providers.include?(id_provider)
                        pkgs += ['sssd-' + id_provider]
                    end
                    if domain_providers.include?(id_provider)
                        pkgs += ['sssd-' + id_provider]
                    end
                }
            end
            if @ldap_pam
                pkgs += ['pam_ldap']
            end
            if @krb_pam
                pkgs += ['pam_krb5', 'krb5', 'krb5-client']
            end
            if @ldap_nss
                pkgs += ['nss_ldap']
                if @ldap_nss.include?('automount')
                    pkgs += ['openldap2-client'] # provides /etc/openldap/ldap.conf
                end
            end
            if @autofs_enabled || @sssd_nss.include?('automount') || @ldap_nss.include?('automount')
                pkgs += ['autofs']
            end
            if @nscd_enabled
                pkgs += ['nscd']
            end
            return pkgs
        end

        # Summarise the authentication configurations in a human-readable, single line of text.
        def summary_text
            # Figure out how authentication works on this computer
            auth_doms_caption = ''
            if !@sssd_enabled && @ldap_nss.empty? && !@ldap_pam && !@krb_pam
                # Local only
                auth_doms_caption = _('Only use local authentication')
            elsif @sssd_enabled && (@sssd_pam || @sssd_nss.any?)
                # SSSD is configured
                if Service.Active('sssd')
                    auth_doms_caption = @sssd_conf['sssd']['domains'].join(', ')
                else
                    auth_doms_caption = _('Configured but not activated')
                end
            else
                # LDAP and/or Kerberos is configured
                if @ldap_nss.any? || @ldap_pam
                    if @ldap_conf['base'].to_s == ''
                        auth_doms_caption = _('LDAP is enabled but the setup is incomplete')
                    else
                        auth_doms_caption = _('via LDAP on ') + @ldap_conf['base']
                    end
                end
                if @krb_pam
                    if auth_doms_caption != ''
                        # 'and' as in "authenticate via LDAP and Kerberos"
                        auth_doms_caption += _(' and ')
                    end
                    realms = @krb_conf.fetch('realms', {})
                    if realms.length == 0
                        auth_doms_caption += _('via Kerberos')
                    else
                        auth_doms_caption += _('via Kerberos on ') + realms.keys.join(', ')
                    end
                end
            end
            return auth_doms_caption
        end

        attr_accessor(:krb_conf, :krb_pam, :ldap_conf, :ldap_pam, :ldap_nss, :sssd_conf, :sssd_pam, :sssd_nss, :sssd_enabled)
        attr_accessor(:autofs_enabled, :nscd_enabled, :mkhomedir_pam)
        attr_accessor(:ad_domain, :ad_user, :ad_ou, :ad_pass, :ad_overwrite_smb_conf, :autoyast_editor_mode, :autoyast_modified)
    end
    AuthConfInst = AuthConf.new
end