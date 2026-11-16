# Repository security setup (owner checklist)

Only the repository owner can change these settings.

**Quick way (recommended):** [`tools/protect-all-repos.sh`](../tools/protect-all-repos.sh) applies sections 1–4 to every
repository you own in one go. It needs the [GitHub CLI](https://cli.github.com) (`gh auth login`).

```bash
bash tools/protect-all-repos.sh            # preview – changes nothing
bash tools/protect-all-repos.sh --apply    # apply
```

Then do section 5 yourself.

**Manual way:** work through the sections below in order. It takes about 15 minutes per repository.

## 1. Security features (do this first)

**Settings → Advanced Security** (called *Code security* on some accounts)

- Enable **Private vulnerability reporting**.
- Enable **Dependency graph**, **Dependabot alerts**, **Dependabot security updates** and **Grouped security updates**.
  The *dependency-review* check needs the dependency graph, and the branch rules below require that check.
- Keep **Secret Protection** and **Push protection** enabled. They are already on.
- **CodeQL:** leave *Default setup* off. The repository uses its own CodeQL workflow (advanced setup).

## 2. Branch and tag rules (rulesets)

**Settings → Rules → Rulesets**

1. Click **New ruleset → Import a ruleset** and choose [`.github/rulesets/protect-main-and-develop.json`](../.github/rulesets/protect-main-and-develop.json)
   (download it from GitHub first). Check that the summary shows the rules below, then click **Create**.
   - Applies to the default branch, `main` and `develop`
   - Blocks deletion and force-pushes
   - Requires a pull request with 1 approval from the code owner. New pushes dismiss approvals, the most recent push
     must be approved by someone else, and conversations must be resolved. Squash merge and merge commits are allowed
     (merge commits for promoting `develop` into `main`).
   - Requires these checks to pass: tests on Windows, macOS and Linux, `dependency-audit`, `Analyze (python)`,
     `Analyze (actions)`, `dependency-review`
   - **Bypass:** only *Repository admin*, and only *for pull requests*. You can merge your own pull requests, since
     GitHub never allows approving your own, but nobody, including you, can push directly.
2. Repeat with [`.github/rulesets/protect-release-tags.json`](../.github/rulesets/protect-release-tags.json).
   Only you can create, move or delete `v*` release tags.
3. **Delete the old ruleset named `main`.** It applies to every branch and stops merged branches from being deleted.

**Settings → Branches**

4. **Delete the classic branch protection rules for `main` and `develop`.** The new ruleset replaces them. If you keep
   them, their "do not allow bypassing" setting combines with the new rules and blocks you from merging your own
   pull requests.

## 3. Pull request settings

**Settings → General → Pull Requests**

- Keep **Allow merge commits** and **Allow squash merging** (set to *Pull request title and description*), and
  untick **Allow rebase merging**.
- Tick **Always suggest updating pull request branches**.
- Tick **Automatically delete head branches**.

**Settings → General → Features:** untick **Wikis**. The wiki isn't used and is edited outside the pull request
workflow. Untick **Projects** as well if you don't use it.

## 4. GitHub Actions

**Settings → Actions → General**

- **Actions permissions:** *Allow devid9602, and select non-devid9602, actions and reusable workflows*. Tick
  *Allow actions created by GitHub*, and under *Allow specified actions* enter `ossf/scorecard-action@*`.
  Also tick **Require actions to be pinned to a full-length commit SHA**.
- **Fork pull request workflows from outside collaborators:** *Require approval for all external contributors*.
- **Workflow permissions:** *Read repository contents and packages permissions*, and untick
  *Allow GitHub Actions to create and approve pull requests*.

**Settings → Environments → New environment** named `release`

- **Required reviewers:** add yourself (`devid9602`). Leave *Prevent self-review* unticked so you can approve your
  own releases.
- **Deployment branches and tags:** *Selected branches and tags* → add a **tag** rule `v*`.

From now on, every release waits for you to click **Review deployments → Approve** before anything is published.

## 5. Your account and access

- Turn on **two-factor authentication**, preferably with a passkey or an authenticator app:
  *GitHub → Settings → Password and authentication*. Your account is the key to everything above.
- Contributors should **fork** the repository and open pull requests. Don't add them as collaborators. If you ever add
  a co-maintainer, give the *Triage* or *Write* role, **never Admin or Maintain**.
- Review **Settings → Applications** (installed GitHub Apps and authorized OAuth apps) and your
  **personal access tokens** now and then. Remove anything you no longer use, including AI-assistant access once you
  are done with a piece of work. The rules above apply to those apps too.

## 6. Releasing a new version

1. Merge the release changes (version number and CHANGELOG) into `main` through a pull request.
2. **Releases → Draft a new release**, type a new tag such as `v1.0.1` (target `main`), add notes, and publish.
3. **Actions → Release builds** waits at *publish*. Click **Review deployments → Approve**.
4. Four downloads, `SHA256SUMS.txt` and signed provenance are attached to the release.
