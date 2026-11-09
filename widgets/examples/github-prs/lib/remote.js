// Parses a GitHub remote URL into {owner, repo}. Loaded before widget.js via manifest "scripts";
// scripts share one global scope, so this is a plain global function.
function parseGitHubRemote(url) {
  const m = /github\.com[:/]([^/]+)\/([^/\s]+?)(?:\.git)?\s*$/.exec(url || "");
  return m ? { owner: m[1], repo: m[2] } : null;
}
