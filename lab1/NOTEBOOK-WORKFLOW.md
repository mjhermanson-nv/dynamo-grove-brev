# Notebook Workflow Guide

This lab uses **Jupytext** and **nbstripout** to maintain clean version control for Jupyter notebooks.

## Tools Installed

### 1. Jupytext
Keeps `.ipynb` and `.md` files in sync. The markdown format is better for:
- Git diffs (see actual content changes)
- Code reviews
- Merge conflicts

### 2. nbstripout
Automatically strips notebook outputs before committing to prevent:
- Large binary diffs
- Merge conflicts in output cells
- Committing sensitive data in outputs

## Recommended Workflow

### Option A: Edit Markdown Files (Recommended)

1. **Edit the `.md` file** with your favorite editor
   ```bash
   vim lab1-introduction-setup.md
   # or
   code lab1-introduction-setup.md
   ```

2. **Sync to notebook**
   ```bash
   jupytext --sync lab1-introduction-setup.md
   ```
   Or use the helper script:
   ```bash
   ./sync-notebooks.sh
   ```

3. **Open in Jupyter** and run cells
   ```bash
   jupyter lab
   ```

4. **Commit changes** - outputs are automatically stripped!
   ```bash
   git add lab1-introduction-setup.md lab1-introduction-setup.ipynb
   git commit -m "Update lab1 content"
   ```

### Option B: Edit Notebook Directly

1. **Open and edit in Jupyter**
   ```bash
   jupyter lab
   ```

2. **Save in Jupyter** - Jupytext auto-syncs to `.md` if configured

3. **Before committing**, sync manually to be safe:
   ```bash
   jupytext --sync lab1-introduction-setup.ipynb
   ```

4. **Commit** - nbstripout automatically strips outputs
   ```bash
   git add lab1-introduction-setup.md lab1-introduction-setup.ipynb
   git commit -m "Update lab1 content"
   ```

## Quick Commands

```bash
# Sync specific file
jupytext --sync lab1-introduction-setup.md

# Sync all paired files
jupytext --sync lab1-*.md

# Convert notebook to markdown (one-time)
jupytext --to md lab1-introduction-setup.ipynb

# Convert markdown to notebook (one-time)
jupytext --to ipynb lab1-introduction-setup.md

# Check if files are in sync
jupytext --test lab1-introduction-setup.md

# Manually strip outputs from notebook
nbstripout lab1-introduction-setup.ipynb
```

## Verification

Check that nbstripout is active:
```bash
git config --get filter.nbstripout.clean
# Should output: jupyter nbconvert --stdin --stdout --to=notebook --ClearOutputPreprocessor.enabled=True ...
```

## Troubleshooting

**Files out of sync?**
```bash
# Force sync from .md to .ipynb
jupytext --sync lab1-introduction-setup.md

# Or from .ipynb to .md
jupytext --sync lab1-introduction-setup.ipynb
```

**Output still being committed?**
```bash
# Verify nbstripout is installed
nbstripout --status
```

**Need to see what changed?**
```bash
# Compare .md files (clean diffs)
git diff lab1-introduction-setup.md
```
