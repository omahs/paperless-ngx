<!--
Note: All PRs with code changes should be targeted to the `dev` branch, pure documentation changes can target `main`
-->

## Proposed change

This PR transitions to Docker image away from supervisord to use [s6](https://skarnet.org/software/s6/overview.html), as provided by [s6-overlay](https://github.com/just-containers/s6-overlay).

### What

s6 is a process supervision suite of tools, and s6-overlay is a nice implemention wrapping them up into useful settings for Docker use. It's the same set of tools used by the [LinuxServer.io](https://www.linuxserver.io/blog/how-is-container-formed) team for their base images.

The previous 2 bash scripts have been broken apart into distinct oneshot services handling a single thing, with dependencies as required. For the most part, start up ordering is identical. I've included a flowchart in the folder of how the startup dependencies are setup.

### Why

In the [second paragraph](http://supervisord.org/) of the `supervisord` documentation, it is noted to not be a proper replacement for PID 1. s6 is a proper PID 1 process supervision suite with some nice utilities for process control as well. It's good to have a proper [PID 1](https://daveiscoding.com/why-do-you-need-an-init-process-inside-your-docker-container-pid-1) for signal handling, clean shutdowns and reaping zombies properly.

All the s6 services, oneshot or longrun can have dependencies defined between them, ensuring and enforcing a valid ordering of startup. This includes more correct handling of optional services like `flower`, which previously was kind of hacky and just allowed to exit, even if it should have started.

## Type of change

<!--
What type of change does your PR introduce to Paperless-ngx?
NOTE: Please check only one box!
-->

- [ ] Bug fix (non-breaking change which fixes an issue)
- [x] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Other (please explain)

## Checklist:

- [x] I have read & agree with the [contributing guidelines](https://github.com/paperless-ngx/paperless-ngx/blob/main/CONTRIBUTING.md).
- [x] If applicable, I have tested my code for new features & regressions on both mobile & desktop devices, using the latest version of major browsers.
- [x] If applicable, I have checked that all tests pass, see [documentation](https://docs.paperless-ngx.com/development/#back-end-development).
- [x] I have run all `pre-commit` hooks, see [documentation](https://docs.paperless-ngx.com/development/#code-formatting-with-pre-commit-hooks).
- [ ] I have made corresponding changes to the documentation as needed.
- [x] I have checked my modifications for any breaking changes.
