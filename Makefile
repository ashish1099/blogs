.PHONY: help serve build new clean submodules

TITLE ?= new-post

help:
	@echo "Usage:"
	@echo "  make serve          - Start Hugo dev server (with drafts)"
	@echo "  make build          - Build site for production"
	@echo "  make new TITLE=...  - Create a new post"
	@echo "  make clean          - Remove build artifacts"
	@echo "  make submodules     - Init/update git submodules (theme)"

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
