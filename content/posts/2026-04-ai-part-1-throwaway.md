+++
title = "AI Part I: On Learning to Throw it All Away"
date = 2026-04-10
description = "Some early thoughts on how today's software engineers must learn to throw away what they know, and what they write."

[extra]
toc = false
comment = false
+++

This is a placeholder first post. More content coming soon.

Here is an example of a sidenote.{% sidenote() %}Sidenotes appear in the right margin on wide screens, and can be toggled inline on mobile.{% end %} The prose continues after the sidenote shortcode.

```rust
        // Wait for delta snapshots on new (target) shards.
        for (target_shard_id, _) in &target_shard_predecessors {
            target_writes
                .get_mut(target_shard_id)
                .expect("target shard writer")
                .wait_for_upper_past(&Antichain::from_elem(DELTA_SNAPSHOT_BATCH_ID))
                .await;
            info!(%target_shard_id, "delta snapshot complete");
        }
```
