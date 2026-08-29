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

add-tenant:
	@NAME="$(NAME)" SESSION="$(SESSION)" WITH_API="$(WITH_API)" sh scripts/add-tenant.sh

backup-now:
	docker compose exec backup /bin/sh /backup.sh
