#!/usr/bin/env bash
set -Eeo pipefail
# TODO add "-u"

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

isLikelyRedmine=
case "$1" in
	rails | rake | passenger ) isLikelyRedmine=1 ;;
esac

_fix_permissions() {
	# https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
	if [ "$(id -u)" = '0' ]; then
		find config files log public/plugin_assets \! -user redmine -exec chown redmine:redmine '{}' +
	fi
	# directories 755, files 644:
	find config files log public/plugin_assets tmp -type d \! -perm 755 -exec chmod 755 '{}' + 2>/dev/null || :
	find config files log public/plugin_assets tmp -type f \! -perm 644 -exec chmod 644 '{}' + 2>/dev/null || :
}

# allow the container to be started with `--user`
if [ -n "$isLikelyRedmine" ] && [ "$(id -u)" = '0' ]; then
	_fix_permissions
	exec gosu redmine "$BASH_SOURCE" "$@"
fi

if [ -n "$isLikelyRedmine" ]; then
	_fix_permissions

	# ensure the right database adapter is active in the Gemfile.lock
	cp "Gemfile.lock.mysql2" Gemfile.lock
	# install additional gems for Gemfile.local and plugins
	bundle check || bundle install --without development test

	if [ ! -s config/secrets.yml ]; then
		file_env 'REDMINE_SECRET_KEY_BASE'
		if [ -n "$REDMINE_SECRET_KEY_BASE" ]; then
			cat > 'config/secrets.yml' <<-YML
				$RAILS_ENV:
				  secret_key_base: "$REDMINE_SECRET_KEY_BASE"
			YML
		elif [ ! -f config/initializers/secret_token.rb ]; then
			rake generate_secret_token
		fi
	fi
	if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
		rake db:migrate
	fi

	if [ "$1" != 'rake' -a -n "$REDMINE_PLUGINS_MIGRATE" ]; then
		rake redmine:plugins:migrate
	fi

	# remove PID file to enable restarting the container
	rm -f tmp/pids/server.pid

	if [ "$1" = 'passenger' ]; then
		# Don't fear the reaper.
		set -- tini -- "$@"
	fi
fi

exec "$@"
