# Notebook Management - Quick Reference

## Daily Workflow

### Method 1: Edit Markdown (Recommended)
```bash
# 1. Edit the .md file
vim lab1-introduction-setup.md

# 2. Sync to notebook
jupytext --sync lab1-introduction-setup.md

# 3. Test in Jupyter
jupyter lab

# 4. Commit (outputs auto-stripped!)
git add lab1-introduction-setup.*
git commit -m "Your message"
```

### Method 2: Edit Notebook
```bash
# 1. Edit in Jupyter
jupyter lab

# 2. Save and sync
jupytext --sync lab1-introduction-setup.ipynb

# 3. Commit (outputs auto-stripped!)
git add lab1-introduction-setup.*
git commit -m "Your message"
```

## Quick Commands

```bash
# Sync all notebooks
./sync-notebooks.sh

# Sync specific file
jupytext --sync lab1-introduction-setup.md

# Verify outputs will be stripped
git add *.ipynb
git diff --cached | grep outputs

# Manually strip outputs
nbstripout lab1-introduction-setup.ipynb
```

## Status Check

```bash
# Check git filter
git config --get filter.nbstripout.clean

# Check git attributes
cat .git/info/attributes

# Check if files are paired
head -15 lab1-introduction-setup.md
# Should show Jupytext config in frontmatter
```

## Troubleshooting

**"Files out of sync"**
```bash
jupytext --sync lab1-introduction-setup.md
```

**"Outputs still being committed"**
```bash
nbstripout --status
nbstripout --install
```

**"Need to unpair files"**
```bash
# Remove Jupytext header from .md file
# Or use: jupytext --update-metadata '{"jupytext": null}' file.ipynb
```
