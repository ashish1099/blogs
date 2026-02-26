.PHONY: help serve build new clean submodules docker-serve docker-build

TITLE ?= new-post

help:
	@echo "Usage:"
	@echo "  make serve          - Start Hugo dev server (with drafts)"
	@echo "  make build          - Build site for production"
	@echo "  make new TITLE=...  - Create a new post"
	@echo "  make clean          - Remove build artifacts"
	@echo "  make submodules     - Init/update git submodules (theme)"
	@echo "  make docker-serve   - Start Hugo dev server via Docker (no local Hugo needed)"
	@echo "  make docker-build   - Build site for production via Docker"

serve:
	hugo server -D

build:
	hugo --gc --minify

new:
	hugo new posts/$(TITLE).md

clean:
	rm -rf public resources/_gen

submodules:
	git submodule update --init --recursive

docker-serve:
	docker compose up

docker-build:
	docker compose run --rm hugo hugo --gc --minify
