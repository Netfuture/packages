-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Matthew Wild, Tobias Markmann, Waqas Hussain

local datamanager = require "util.datamanager";
local log = require "util.logger".init("auth_internal_hashed");
local getAuthenticationDatabaseSHA1 = require "util.sasl.scram".getAuthenticationDatabaseSHA1;
local usermanager = require "core.usermanager";
local generate_uuid = require "util.uuid".generate;
local new_sasl = require "util.sasl".new;

local to_hex;
do
	local function replace_byte_with_hex(byte)
		return ("%02x"):format(byte:byte());
	end
	function to_hex(binary_string)
		return binary_string:gsub(".", replace_byte_with_hex);
	end
end

local from_hex;
do
	local function replace_hex_with_byte(hex)
		return string.char(tonumber(hex, 16));
	end
	function from_hex(hex_string)
		return hex_string:gsub("..", replace_hex_with_byte);
	end
end

-- Default; can be set per-user
local iteration_count = 4096;

function new_hashpass_provider(host)
	local provider = { name = "internal_hashed" };
	log("debug", "initializing internal_hashed authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if credentials.password ~= nil and string.len(credentials.password) ~= 0 then
			if credentials.password ~= password then
				return nil, "Auth failed. Provided password is incorrect.";
			end

			if provider.set_password(username, credentials.password) == nil then
				return nil, "Auth failed. Could not set hashed password from plaintext.";
			else
				return true;
			end
		end

		if credentials.iteration_count == nil or credentials.salt == nil or string.len(credentials.salt) == 0 then
			return nil, "Auth failed. Stored salt and iteration count information is not complete.";
		end
		
		local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, credentials.salt, credentials.iteration_count);
		
		local stored_key_hex = to_hex(stored_key);
		local server_key_hex = to_hex(server_key);
		
		if valid and stored_key_hex == credentials.stored_key and server_key_hex == credentials.server_key then
			return true;
		else
			return nil, "Auth failed. Invalid username, password, or password hash information.";
		end
	end

	function provider.set_password(username, password)
		local account = datamanager.load(username, host, "accounts");
		if account then
			account.salt = account.salt or generate_uuid();
			account.iteration_count = account.iteration_count or iteration_count;
			local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, account.salt, account.iteration_count);
			local stored_key_hex = to_hex(stored_key);
			local server_key_hex = to_hex(server_key);
			
			account.stored_key = stored_key_hex
			account.server_key = server_key_hex

			account.password = nil;
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available.";
	end

	function provider.user_exists(username)
		local account = datamanager.load(username, host, "accounts");
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed. Invalid username";
		end
		return true;
	end

	function provider.create_user(username, password)
		if password == nil then
			return datamanager.store(username, host, "accounts", {});
		end
		local salt = generate_uuid();
		local valid, stored_key, server_key = getAuthenticationDatabaseSHA1(password, salt, iteration_count);
		local stored_key_hex = to_hex(stored_key);
		local server_key_hex = to_hex(server_key);
		return datamanager.store(username, host, "accounts", {stored_key = stored_key_hex, server_key = server_key_hex, salt = salt, iteration_count = iteration_count});
	end

	function provider.delete_user(username)
		return datamanager.store(username, host, "accounts", nil);
	end

	function provider.get_sasl_handler()
		local testpass_authentication_profile = {
			plain_test = function(sasl, username, password, realm)
				return usermanager.test_password(username, realm, password), true;
			end,
			scram_sha_1 = function(sasl, username, realm)
				local credentials = datamanager.load(username, host, "accounts");
				if not credentials then return; end
				if credentials.password then
					usermanager.set_password(username, credentials.password, host);
					credentials = datamanager.load(username, host, "accounts");
					if not credentials then return; end
				end
				
				local stored_key, server_key, iteration_count, salt = credentials.stored_key, credentials.server_key, credentials.iteration_count, credentials.salt;
				stored_key = stored_key and from_hex(stored_key);
				server_key = server_key and from_hex(server_key);
				return stored_key, server_key, iteration_count, salt, true;
			end
		};
		return new_sasl(module.host, testpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_hashpass_provider(module.host));
