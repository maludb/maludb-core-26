# PageIndex / ChatIndex — Technology Guide

Conceptual brief for MaluDB Version 4. Frozen reference; not normative.

This guide explains what PageIndex and ChatIndex are as upstream concepts, how they map onto MaluDB's existing memory model, and which doctrine boundaries V4 has to respect. The implementation plan in [`../../version4-pageindex-plan.md`](../../version4-pageindex-plan.md) governs how the concept lands in code; the upstream source repositories are the canonical reference for the concept itself.

**Upstream sources**

- `https://github.com/VectifyAI/PageIndex` — MIT-licensed Python implementation of tree-of-summaries for document retrieval.
- `https://github.com/VectifyAI/ChatIndex` — Apache-2.0 extension of PageIndex for ongoing conversational transcripts.

---

## 1. PageIndex in one paragraph

PageIndex builds a tree-of-summaries over a single document. Each internal node holds a summary of the section it covers; each leaf holds a summary plus an anchor to a contiguous byte/page range of the source. At retrieval time, an LLM is given the root's children, asked to pick the one most likely to contain the answer, then handed that node's children, and so on until it reaches a leaf or chooses to stop. The descent prompt is the navigation mechanism — no vector similarity is consulted to choose a child. The upstream guide refers to this as "vectorless retrieval."

The shape of a PageIndex node, in upstream terms:

```
{ title, node_id, start_index, end_index, summary, nodes[] }
```

`start_index` and `end_index` describe the source range the node covers; `summary` is an LLM-generated abstract; `nodes` is the list of children. Leaves carry the same shape with `nodes = []`.

## 2. ChatIndex in one paragraph

ChatIndex extends PageIndex to chat transcripts. Instead of a fixed document, the tree grows as new messages arrive. ChatIndex distinguishes two node kinds:

```
TopicNode    { topic_name, summary, start_index, end_index, children, sub_node_count }
MessageNode  { system_message, user_message, assistant_message, message_index }
```

The tree maintains a *current node* pointer. New messages either extend the current leaf (under the current TopicNode) or open a new TopicNode as a sibling of the current node or of one of its ancestors. ChatIndex does not allow opening a new topic from an unrelated branch — once the conversation diverges, the new topic has to attach somewhere on the path back to the root.

## 3. "Vectorless" navigation, two-stage retrieval

The upstream "vectorless retrieval" framing applies to **navigation within a known document**: once you have the right tree, the LLM walks it without any vector search inside. It does not say "vectors are not used to find the document in the first place."

MaluDB resolves the framing this way: V4 retrieval is **two-stage**.

1. **Stage 1 — discovery.** SVPOR-framed embeddings, FTS, catalog filters, and graph traversal find the candidate Source Packages within a project/subject partition. This is the existing Stage-4 retrieval planner, unchanged.
2. **Stage 2 — navigation.** When the resolved Source Packages have PageIndex (or ChatIndex) trees attached, the planner can use tree descent as an additional retrieval path. The LLM walks the tree as upstream describes.

This preserves SVPOR-framed embeddings as the discovery layer — V4 does not remove or weaken them. Tree descent is one more search path the planner can choose, not a replacement.

## 4. Build pipeline

Both trees are built in two passes:

- **Pass 1 — deterministic structure.** Outline extraction. For PDFs this means parsing the embedded `/Outlines`, or detecting heading boundaries when no outline is present. For markdown it's header parsing. For plain text it's a degenerate single-leaf tree. For chat transcripts it's message-author boundaries plus optional time-gap topic candidates. Determinism is the contract: the same input bytes always produce the same leaf ranges, regardless of which model alias runs next.
- **Pass 2 — LLM summarization.** With leaf ranges fixed, the builder calls the model gateway to produce a summary for each leaf, then for each internal node. The prompt template is pinned per build. Re-derivation under a new model alias changes summaries; it never changes boundaries.

This split is non-negotiable in MaluDB: it is what makes a re-derived tree comparable to its predecessor, and what lets the V3-EMBED-01 chunker consume tree leaf ranges as precomputed boundaries (so vector chunks align 1:1 with tree leaves).

## 5. How MaluDB adopts the concept

Five concrete adaptations bake into the V4 design.

1. **Trees are derived artifacts.** A PageIndex or ChatIndex tree has the same status as a `malu$vector_chunk` row or a Derivation Ledger entry — produced from a Source Package by a governed pipeline. Trees are not first-class memory objects. They specialize existing objects rather than introducing a new top-level kind.
2. **Nodes specialize `malu$memory_detail_object` (MDO).** A new `mdo_kind` discriminator column on the MDO table distinguishes the existing memory detail (`'memory_detail'`) from tree nodes (`'page_index_node'`, `'chat_index_topic'`, `'chat_index_message'`). Existing MDO consumers continue to read the table directly; the discriminator defaults to `'memory_detail'` so their behavior is unchanged.
3. **SVPOR-framed embeddings on summaries.** When a tree-node summary is embedded for cross-document discovery, it is SVPOR-framed: `subject = <document subject>`, `verb = 'summarizes'`, `object = <section title path>`, predicate fields drawn from the heading lineage. This is mandatory — it is what keeps tree-summary embeddings retrievable through the same authorization-aware retrieval coordinator as every other embedding.
4. **Three-stage authorization on descent.** Planning chooses *which trees* are visible based on Source Package authorization. Candidate expansion (the LLM picking a child) sees only authorized siblings — the descent prompt is constructed from the authz-filtered set. Result assembly redacts unauthorized leaves before returning. The LLM never sees an unauthorized sibling; the choice is re-checked against the filtered set before traversal.
5. **Supersession on re-derivation.** A re-derived tree under a new model alias does not overwrite the prior tree. The prior `malu$page_index_tree` row transitions to `build_status = 'superseded'`, a fresh row is opened, and a `supersedes` edge connects them. Leaf ranges remain valid; summaries are new. The Temporal Supersession Engine owns the transition.

## 6. What MaluDB does NOT take from PageIndex

- **The "vectorless" framing as a system-wide property.** MaluDB still uses vector and SVPOR-framed embeddings for discovery. The descent prompt is vectorless; the planner around it is not.
- **The upstream Python implementation.** Both upstream repos are referenced for concept and node shape only; MaluDB ships its own builder in `services/maludb-pageindexd/` against the MaluDB catalog and the V3 queue.
- **Vision PDFs.** Scanned / image-only PDFs are explicitly deferred. V4 text-bearing PDFs only.
- **AGPL parsers.** `PyMuPDF` (AGPL-3.0) is operator-pluggable but is not bundled in the default redistributed product. `pypdf` (BSD-3-Clause) is the V4 default.
- **An "AMP retire → ChatIndex build" automation.** Active Memory Pools are live working sets; ChatIndex is a retrospective tree over a retired transcript. The bridge between them is out of v4.0.0 scope.

## 7. Where to read next

- The implementation plan: [`../../version4-pageindex-plan.md`](../../version4-pageindex-plan.md). Per-ticket deliverables, migration assignments, acceptance criteria.
- The upstream concept: VectifyAI/PageIndex and VectifyAI/ChatIndex READMEs.
- The MaluDB invariants this concept must preserve: [`../../requirements.md`](../../requirements.md) §3 (memory object model, SVPOR, MAUT, bitemporal, derivation ledger), §4 (retrieval), §5 (security), §9 (phased plan).
