# Getting help

This repository holds the Polysite deployment files (Helm chart, proxy configurations, templates). Polysite is pre-1.0 and kept by a small team, so this page says plainly where to ask and what to expect.

## Where to ask

- **A question about using it:** read the README of the folder you are using and the core's [guides](https://github.com/polysites/polysite/tree/main/docs/guide) first. If they do not answer it,
  open an issue on the core repository and choose the question option. Discussion of any topic starts as an issue.
- **Something is broken:** open an issue with the *Bug report* form. The more of the form you fill in (version, how you run it, the steps), the sooner it can be reproduced.
- **An idea:** open an issue with the *Feature request* form before writing a large change. See CONTRIBUTING.md in the core repository.
- **A security problem:** do not open an issue. Follow the core repository's [SECURITY.md](https://github.com/polysites/polysite/blob/main/SECURITY.md).
- **Conduct:** see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## What is supported

- The current `main` branch and the most recent tagged release, run the documented way: Docker Compose, with the images or the source in this project.
- Reports that you can reproduce on a fresh install with the demo data.

## What is not

- Your own changes to the code, the compose files or the proxy configuration, and forks. Questions are welcome; fixes are up to you.
- The software Polysite builds on (Payload, Next.js, Nuxt, PostgreSQL, Caddy, Docker): report those to their own projects.
- Running, securing and backing up your server and domains, beyond what the guides say.
- Individual help with a theme or a site build. For commercial arrangements, write to info@quicksupporttoday.com.

## What to expect

Nobody is on call. The maintainers read new issues as time allows, usually within a few working days, and cannot promise an answer, a fix
or a date. Security reports are handled as the security policy says. There is no service-level agreement.
