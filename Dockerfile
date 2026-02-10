FROM hugomods/hugo:exts-0.147.0

EXPOSE 1313

ENTRYPOINT ["hugo", "server", "--bind", "0.0.0.0", "-D", "--baseURL", "http://localhost:1313/"]
