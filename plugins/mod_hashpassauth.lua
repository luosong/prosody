-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2010 Jeff Mitchell
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local datamanager = require "util.datamanager";
local log = require "util.logger".init("usermanager");
local type = type;
local error = error;
local ipairs = ipairs;
local hashes = require "util.hashes";
local jid_bare = require "util.jid".bare;
local saltedPasswordSHA1 = require "util.sasl.scram".saltedPasswordSHA1;
local config = require "core.configmanager";
local usermanager = require "core.usermanager";
local generate_uuid = require "util.uuid".generate;
local hosts = hosts;

local prosody = _G.prosody;

local is_cyrus = usermanager.is_cyrus;

-- Default; can be set per-user
local iteration_count = 4096;

function new_hashpass_provider(host)
	local provider = { name = "hashpass" };
	log("debug", "initializing hashpass authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		log("debug", "test password for user %s at host %s", username, module.host);
		if is_cyrus(host) then return nil, "Legacy auth not supported with Cyrus SASL."; end
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if credentials.hashpass == nil or credentials.iteration_count == nil or credentials.salt == nil then
			return nil, "Auth failed. Stored credential information is not complete.";
		end

		local valid, binpass = saltedPasswordSHA1(password, credentials.salt, credentials.iteration_count);
		local hexpass = binpass:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
		if valid then
			log("debug", "salted password returned valid");
		else
			log("debug", "salted password returned not valid");
		end
		log("debug", "hexpass is '%s', stored pass is '%s'", hexpass, credentials.hashpass);
		if valid and hexpass == credentials.hashpass then
			return true;
		else
			return nil, "Auth failed. Invalid username, password, or password hash information.";
		end
	end

	function provider.get_password(username)
		log("debug", "get_password for username '%s' at host '%s'", username, module.host);
		if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
		return (datamanager.load(username, host, "accounts") or {}).hashpass;
	end
	
	function provider.set_password(username, password)
		if is_cyrus(host) then return nil, "Passwords unavailable for Cyrus SASL."; end
		local account = datamanager.load(username, host, "accounts");
		if account then
			if account.iteration_count == nil then
				account.iteration_count = iteration_count;
			end

			if account.salt == nil then
				account.salt = generate_uuid();
			end

			local valid, binpass = saltedPasswordSHA1(password, account.salt, account.iteration_count);
			local hexpass = binpass:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
			account.hashpass = hexpass;

			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available.";
	end

	function provider.user_exists(username)
		if is_cyrus(host) then return true; end
		local account = datamanager.load(username, host, "accounts");
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed. Invalid username";
		end
		if account.hashpass == nil or string.len(account.hashpass) == 0 then
			log("debug", "account password not set or zero-length for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed. Password invalid.";
		end
		return true;
	end

	function provider.create_user(username, password)
		if is_cyrus(host) then return nil, "Account creation/modification not available with Cyrus SASL."; end
		local salt = generate_uuid();
		local valid, binpass = saltedPasswordSHA1(password, salt, iteration_count);
		local hexpass = binpass:gsub(".", function (c) return ("%02x"):format(c:byte()); end);
		return datamanager.store(username, host, "accounts", {hashpass = hexpass, salt = salt, iteration_count = iteration_count});
	end

	function provider.get_supported_methods()
		return {["PLAIN"] = true}; -- TODO this should be taken from the config
	end

	function provider.is_admin(jid)
		local admins = config.get(host, "core", "admins");
		if admins ~= config.get("*", "core", "admins") and type(admins) == "table" then
			jid = jid_bare(jid);
			for _,admin in ipairs(admins) do
				if admin == jid then return true; end
			end
		elseif admins then
			log("error", "Option 'admins' for host '%s' is not a table", host);
		end
		return is_admin(jid); -- Test whether it's a global admin instead
	end
	return provider;
end

module:add_item("auth-provider", new_hashpass_provider(module.host));
