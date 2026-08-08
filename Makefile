.PHONY: up down restart logs ps add-tenant backup-now

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

ps:
	docker compose ps

# Add a tenant to a running engine.
#   make add-tenant NAME=<name>
#   make add-tenant NAME=<name> SESSION=1     # DSN names the session door
#   make add-tenant NAME=<name> WITH_API=1    # also builds the PostgREST roles
add-tenant:
	@NAME="$(NAME)" SESSION="$(SESSION)" WITH_API="$(WITH_API)" sh scripts/add-tenant.sh

# Run the backup once, now, instead of waiting for the schedule.
backup-now:
	docker compose exec backup /bin/sh /backup.sh
