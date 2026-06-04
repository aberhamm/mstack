## Step 5: Cluster by approach

After scoring and trap detection, group ideas by their underlying approach
angle. Two ideas from different frames that both propose the same
architectural bet belong in the same cluster, even if their surface
features differ.

### Clustering prompt

```
Group these scored ideas by their underlying approach, not by surface-level
features or the frame that generated them, but by the fundamental
architectural bet they are making. Name each cluster with a 3-5 word label.
```

### Cluster output format

```
Clusters:
  "<3-5 word label>": ideas #<N>, #<N> (from <frame>, <frame>)
  "<3-5 word label>": ideas #<N>, #<N> (from <frame>, <frame>)
  "<3-5 word label>": idea #<N> (from <frame>)

Convergence signal: <N> frames independently proposed <cluster label> approaches
  -> higher confidence in this direction
```

**Convergence signals:** When two or more frames independently produce ideas
that land in the same cluster, that is a convergence signal. It means the
approach is robust across different evaluation perspectives and deserves
higher confidence. Call this out explicitly for every cluster with 2+ source
frames.

Singleton clusters (one idea, one frame) are fine. They represent unique
angles that only one perspective surfaced.
