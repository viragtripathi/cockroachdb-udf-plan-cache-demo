BEFORE_URL ?= postgresql://root@localhost:26262/udfdemo?sslmode=disable
AFTER_URL  ?= postgresql://root@localhost:26263/udfdemo?sslmode=disable
BOOT_BEFORE = postgresql://root@localhost:26262/defaultdb?sslmode=disable
BOOT_AFTER  = postgresql://root@localhost:26263/defaultdb?sslmode=disable

PG_INCLUDE := $(shell pkg-config --cflags libpq 2>/dev/null || echo -I$$(pg_config --includedir))
PG_LIBS    := $(shell pkg-config --libs libpq 2>/dev/null || echo -L$$(pg_config --libdir) -lpq)

COMPOSE ?= $(shell command -v docker >/dev/null 2>&1 && echo "docker compose" || echo "podman compose")

.PHONY: all up down build setup trace demo clean

all: up build setup demo

up:
	$(COMPOSE) up -d --wait

down:
	$(COMPOSE) down -v

build: bench/pqbench

bench/pqbench: bench/pqbench.c
	$(CC) -O2 -o $@ $< $(PG_INCLUDE) $(PG_LIBS)

setup:
	./scripts/setup.sh "$(BOOT_BEFORE)"
	./scripts/setup.sh "$(BOOT_AFTER)"

# psql-only proof: cached plan reused vs rebuilt, per UDF call shape
trace:
	@echo "== before"; ./scripts/trace_reuse.sh "$(BEFORE_URL)"
	@echo; echo "== after"; ./scripts/trace_reuse.sh "$(AFTER_URL)"

# Full matrix; writes results/<version>.md for each cluster
demo: build
	./scripts/run_matrix.sh "$(BEFORE_URL)" results/before.md
	./scripts/run_matrix.sh "$(AFTER_URL)" results/after.md
	@head -1 results/before.md; head -1 results/after.md

clean:
	rm -f bench/pqbench
