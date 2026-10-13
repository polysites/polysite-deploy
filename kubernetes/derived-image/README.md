# Images with your plugins and themes

The published images (`ghcr.io/polysites/polysite-cms`, `-web`) contain the core only. A site that uses plugins or themes builds its own images; `build.sh` here does it
with the core's own Dockerfiles. See the script's header for why "FROM the published image, COPY the plugins" does not work (plugins and themes are compiled in at build time).

```bash
./build.sh --core v0.1.0 --plugins ../plugins --themes ../themes --registry registry.example.org/acme --tag v0.1.0-acme1 --push
helm upgrade polysite ... --set image.registry=registry.example.org/acme --set image.tag=v0.1.0-acme1 \
  --set image.backup.registry=ghcr.io/polysites --set image.backup.tag=v0.1.0
```

Plugins add database tables of their own; their migrations are applied by the same migration Job (`payload migrate` runs the core's and every installed plugin's). Keep the `--core` tag and the
chart version in step. Tested: the build assembles the context and builds the images; running a plugin-bearing image in the cluster was not repeated for every plugin.
