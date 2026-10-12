# Security

OffSight is open-source software provided **as is**, without warranty or guaranteed support (see [LICENSE](LICENSE)). Security reports are still very welcome.

## Reporting a vulnerability

Please report security problems **privately** through GitHub's [private vulnerability reporting](https://github.com/astatine-/offsight/security/advisories/new), not in a public issue.

The most important class of problem is anything that lets a meeting app (or any other process) receive **live camera video without the user's approval**, or stops OffSight failing closed to the placeholder. Examples:

- frames reaching OffSight Camera's output from anything other than OffSight.app;
- live video continuing after the shutter is closed, a session ends, or the Mac sleeps;
- an app being approved without the user clicking **Go live**.

Include the macOS version, the OffSight version, steps to reproduce and, if you can, the output of **Settings › Advanced › Copy Diagnostics**.

Reports are read when time allows. There is no committed response time or bounty.
