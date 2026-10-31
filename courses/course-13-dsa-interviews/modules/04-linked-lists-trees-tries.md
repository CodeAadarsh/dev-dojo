# Linked Lists, Trees & Tries

> **Module 04 · Course 13** — Pointer problems look deceptively simple on paper. The interview room is where you discover your mental model has a subtle off-by-one. This module fixes the model, not the specific question — because Tier-1 interviewers rotate questions constantly but test the same five pointer-manipulation patterns every time.

You already know what a linked list is. The questions you'll face don't test that — they test whether you can **reason about pointer state during mutation** without drawing twelve boxes on a whiteboard.

---

## Linked Lists

### The dummy-head pattern

Any time you're building or modifying a list where the head might change — merge two lists, remove nth from end, insert at position 0 — create a sentinel:

```python
dummy = ListNode(0)
dummy.next = head
cur = dummy
# ... work with cur ...
return dummy.next
```

Without a dummy, every branch needs `if not prev: head = node else: prev.next = node`. With it, every insertion and deletion looks identical. This isn't a trick — it's the right abstraction for the problem.

### Fast/slow pointers (Floyd's technique)

Two pointers, one advancing twice per step:

```python
def has_cycle(head: "ListNode") -> bool:
    slow = fast = head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow is fast:
            return True
    return False
```

One pattern, four applications — internalize the math:

| Problem | What to do |
|---------|-----------|
| Detect cycle | Return True when `slow is fast` |
| Find cycle entry | After detection, reset one pointer to `head`; advance both at speed 1; they meet at the entry |
| Middle of list | When `fast` reaches the end, `slow` is at middle |
| Kth from end | Advance `fast` k steps first; then advance both until `fast` is None; `slow` is k-from-end |

The math for cycle entry: let `F` = distance from head to entry, `C` = cycle length, `k` = extra steps fast traveled inside the cycle. After detection, `slow` is `F mod C` steps into the cycle. Resetting one pointer to head and advancing both at speed 1 means they travel `F` more steps — meeting exactly at the entry.

```python
def detect_cycle(head: "ListNode") -> "ListNode":
    slow = fast = head
    while fast and fast.next:
        slow, fast = slow.next, fast.next.next
        if slow is fast:
            slow = head                   # reset one pointer
            while slow is not fast:       # advance both at speed 1
                slow, fast = slow.next, fast.next
            return slow                   # cycle entry
    return None
```

### Reversing in-place

The three-pointer dance:

```python
def reverse_list(head: "ListNode") -> "ListNode":
    prev, cur = None, head
    while cur:
        nxt = cur.next      # save BEFORE the overwrite — always first
        cur.next = prev
        prev = cur
        cur = nxt
    return prev
```

Every reversal variant — sublist, k-group — is this loop with extra bookkeeping around it.

### Reversing a sublist [m, n] (one pass)

```python
def reverse_between(head: "ListNode", m: int, n: int) -> "ListNode":
    dummy = ListNode(0, head)
    pre = dummy
    for _ in range(m - 1):
        pre = pre.next              # land just before position m

    cur = pre.next
    for _ in range(n - m):
        nxt = cur.next
        cur.next = nxt.next
        nxt.next = pre.next
        pre.next = nxt              # insert nxt at the front of the reversed segment
    return dummy.next
```

Draw this once for `m=2, n=4, list=[1,2,3,4,5]`. After the first iteration: `[1,3,2,4,5]`; after the second: `[1,4,3,2,5]`. Understand the invariant — `pre.next` always points to the tail of the reversed segment — and you'll never need to draw it again.

---

## Binary Trees

### All four traversals — recursive and iterative

You need both forms. Recursive is natural; iterative is what you reach for when the interviewer says "assume the tree can be degenerate."

**Inorder (left-root-right):**

```python
def inorder_recursive(root: "TreeNode") -> list:
    if not root:
        return []
    return inorder_recursive(root.left) + [root.val] + inorder_recursive(root.right)

def inorder_iterative(root: "TreeNode") -> list:
    result, stack, cur = [], [], root
    while cur or stack:
        while cur:              # go as far left as possible
            stack.append(cur)
            cur = cur.left
        cur = stack.pop()       # process
        result.append(cur.val)
        cur = cur.right         # move right
    return result
```

**Preorder (root-left-right):** move `result.append(cur.val)` before the inner `while cur` loop.

**Postorder (left-right-root):** cleanest iterative form is reverse-preorder — visit root, go right first, go left second, then reverse the result list.

**Level-order (BFS):**

```python
from collections import deque

def level_order(root: "TreeNode") -> list[list]:
    if not root:
        return []
    q, result = deque([root]), []
    while q:
        level = []
        for _ in range(len(q)):         # snapshot the level size before the loop
            node = q.popleft()
            level.append(node.val)
            if node.left:  q.append(node.left)
            if node.right: q.append(node.right)
        result.append(level)
    return result
```

The `range(len(q))` trick is cleaner than inserting `None` sentinels — no forgotten re-inserts, no off-by-one when the level boundary shifts.

### BST — the global-bounds rule

In a valid BST, **every** node in the left subtree must be strictly less than the root, and **every** node in the right subtree must be strictly greater. "Strictly less than the immediate parent" is not the same thing.

```python
def is_valid_bst(root: "TreeNode",
                 lo: float = float('-inf'),
                 hi: float = float('inf')) -> bool:
    if not root:
        return True
    if not (lo < root.val < hi):
        return False
    return (is_valid_bst(root.left,  lo,       root.val) and
            is_valid_bst(root.right, root.val, hi))
```

The buggy version checks only `root.left.val < root.val < root.right.val`. It fails for this tree:

```
       10
      /  \
     5    15
         /
        6     ← 6 < 10 violates the global left-subtree bound; local check passes
```

BST inorder property: a valid BST's inorder traversal is strictly sorted. You can validate by doing an inorder traversal and asserting each value is greater than the previous.

### Lowest Common Ancestor (LCA)

```python
def lca(root: "TreeNode", p: "TreeNode", q: "TreeNode") -> "TreeNode":
    if not root or root is p or root is q:
        return root
    left  = lca(root.left,  p, q)
    right = lca(root.right, p, q)
    return root if (left and right) else (left or right)
```

The logic: if p and q are found on different sides, `root` is the LCA. If both are on one side, the answer is deeper in that subtree. This handles the edge case where one node is an ancestor of the other — the base case `root is p` returns early.

For a **BST** specifically, skip the general LCA and exploit the order: walk from root, if both p and q are smaller go left, if both are larger go right, otherwise the current node is the LCA.

---

## Tries

A trie stores strings so that prefix lookups are O(L) where L is the string length, regardless of how many strings are in the collection. Every node represents a prefix; the path from root to a marked node spells a complete word.

```python
class TrieNode:
    __slots__ = ("children", "is_end")

    def __init__(self):
        self.children: dict[str, "TrieNode"] = {}
        self.is_end: bool = False


class Trie:
    def __init__(self):
        self.root = TrieNode()

    def insert(self, word: str) -> None:
        node = self.root
        for ch in word:
            if ch not in node.children:
                node.children[ch] = TrieNode()
            node = node.children[ch]
        node.is_end = True              # mark ONLY the final node

    def search(self, word: str) -> bool:
        node = self.root
        for ch in word:
            if ch not in node.children:
                return False
            node = node.children[ch]
        return node.is_end              # False if word is only a prefix

    def starts_with(self, prefix: str) -> bool:
        node = self.root
        for ch in prefix:
            if ch not in node.children:
                return False
            node = node.children[ch]
        return True
```

**Wildcard matching** (`.` matches any character): replace the character loop with a DFS that branches on `.`:

```python
def search_with_wildcards(self, word: str) -> bool:
    def dfs(node: TrieNode, i: int) -> bool:
        if i == len(word):
            return node.is_end
        ch = word[i]
        if ch == '.':
            return any(dfs(child, i + 1) for child in node.children.values())
        if ch not in node.children:
            return False
        return dfs(node.children[ch], i + 1)
    return dfs(self.root, 0)
```

**When to reach for a trie vs. a hash set:**
- Hash set: exact lookups. O(L) amortized. Simpler.
- Trie: prefix queries, autocomplete, "find all words with this prefix," or wildcard/regex matching. The extra structure pays for itself only when you need prefix traversal.

---

## Common Mistakes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Rest of list disappears after reversal | `cur.next = prev` before saving `nxt = cur.next` | First line inside the loop, always: `nxt = cur.next` |
| `is_valid_bst` returns True for an invalid tree | Checking only against immediate parent | Propagate `(lo, hi)` bounds through every recursive call |
| Cycle entry is wrong node | Resetting both pointers to `head` after detection | Reset only one pointer to `head`; keep the other at the meeting point |
| Level-order returns wrong groupings | Using `None` sentinels and forgetting to re-insert them | Use the `range(len(q))` snapshot — it's cleaner and never wrong |
| Trie `search` returns True for a bare prefix | Marking `is_end = True` on every node along the path | Mark `is_end` only on the final character's node |
| Stack overflow on a deep tree | Using recursive traversal on a degenerate (linear) tree | Use iterative traversal with an explicit stack |
| `lca` returns wrong node when one target is ancestor of the other | Missing the `root is p or root is q` base case | The base case must short-circuit before descending |

> **War story.** I was 40 minutes into a Meta phone screen when the interviewer asked me to validate a BST. I wrote the local-comparison version — `root.left.val < root.val < root.right.val` — and it passed their small test case. Then they asked: "what does your code return for this tree?" and sketched `10 → 5 → 15` with a node `6` as the left child of `15`. My code returned True. Correct answer: False, because 6 < 10 violates the root's left-subtree global bound. I had memorized the pattern without understanding *why* bounds must propagate. I've never forgotten it since — and I've caught the exact same bug in three production code reviews at SAP, always from a junior who reproduced the same mental shortcut.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Implement fast/slow cycle detection and then find the cycle entry node in one sitting — explain the math for why resetting one pointer to `head` works.
2. Write both recursive and iterative inorder traversal; state when you'd choose the iterative form.
3. Implement `is_valid_bst` with propagated bounds and give a concrete example tree that the parent-only version gets wrong.
4. Reverse a linked list sublist `[m, n]` in one pass; state the invariant that makes the inner loop correct.
5. Implement a `Trie` with `insert`, `search`, and `starts_with`; explain the difference in what `is_end` means vs what absence of a child means.
6. State which traversal you'd use for: (a) sorted output from a BST, (b) printing tree level by level, (c) finding the LCA, (d) checking if a word exists in a set of strings with prefix constraints.

➡ Next up: **Graphs** — where the mistakes graduate from "lost a pointer" to "infinite loops on an unmarked cycle."
