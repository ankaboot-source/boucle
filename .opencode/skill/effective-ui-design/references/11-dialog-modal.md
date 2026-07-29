# Dialogs & Modals

Use the native `<dialog>` element and Popover API to build accessible, well-structured overlays without JavaScript libraries.

## The `<dialog>` Element

The `<dialog>` element supports two modes of operation:

### `.showModal()` -- Modal Dialog

- Opens in the top layer, above all other content
- Renders a `::backdrop` pseudo-element behind it
- Makes the rest of the page inert (no interaction possible)
- Traps focus within the dialog automatically
- Closes on Escape key by default (fires `cancel` event, then `close`)
- Has implicit `aria-modal="true"`
- Focus moves to the first focusable element (or the element with `autofocus`)
- On close, focus returns to the element that opened the dialog

### `.show()` -- Non-Modal Dialog

- Opens without a backdrop
- Does NOT make the rest of the page inert
- Does NOT trap focus
- Does NOT close on Escape by default
- Has implicit `aria-modal="false"`
- Use for tool palettes, inspectors, supplementary panels

**Key rule:** Never toggle the `open` attribute directly. Always use `.show()` or `.showModal()` methods. Setting the `open` attribute via HTML creates a non-modal dialog without proper accessibility setup.

### `<form method="dialog">` and `returnValue`

Buttons inside a `<form method="dialog">` close the dialog without JavaScript and without submitting the form. The button's `value` becomes `dialog.returnValue`.

```html
<dialog id="confirm">
  <form method="dialog">
    <p>Save changes?</p>
    <button value="cancel">Cancel</button>
    <button value="confirm">Save changes</button>
  </form>
</dialog>
```

```javascript
const dialog = document.getElementById("confirm");

dialog.addEventListener("close", () => {
  if (dialog.returnValue === "confirm") {
    saveChanges();
  }
});
```

**Source:** [MDN `<dialog>` Element](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/dialog), [web.dev Building a Dialog Component](https://web.dev/articles/building/a-dialog-component)

## Dialog vs Popover API

| Feature | `<dialog>` + `.showModal()` | `<dialog>` + `.show()` | Popover API |
|---|---|---|---|
| Top layer | Yes | No | Yes |
| Backdrop | Yes (`::backdrop`) | No | No |
| Page inert | Yes | No | No |
| Focus trapping | Yes (native) | No | No |
| Light dismiss | Only with `closedby="any"` | No | Yes (default for `popover="auto"`) |
| Escape to close | Yes (default) | No | Yes (for `popover="auto"`) |
| Focus restoration | Yes | Yes | No (must implement) |
| Semantic role | `dialog` | `dialog` | None (inherits from element) |

### Use `<dialog>` (Modal) When

- The user MUST address something before continuing (confirmation, critical alert)
- You need focus trapping (accessibility requirement for modal interactions)
- The task requires a decision or data entry that blocks the main workflow
- Confirming destructive or irreversible actions

### Use `<dialog>` (Non-Modal) When

- Supplementary content that does not block the main task
- Tool panels, inspectors, find-and-replace

### Use Popover API When

- Tooltips, hover cards, teaching UI
- Dropdown menus, action menus
- Toast notifications
- Content pickers, colour pickers
- Any UI that should "light dismiss" when clicking outside
- No semantic "dialog" role is needed

### Combining Both

`<dialog popover>` is valid HTML. This gives you dialog semantics with popover control (including light dismiss). Useful for non-modal dialogs that should dismiss when clicking outside.

**Sources:** [Hidde de Vries -- Dialog, Modal, Popover Differences](https://hidde.blog/dialog-modal-popover-differences/), [Frontend Masters -- Dialog vs Popovers](https://frontendmasters.com/blog/whats-the-difference-between-htmls-dialog-element-and-popovers/), [CSS-Tricks -- Popovers and Dialogs](https://css-tricks.com/clarifying-the-relationship-between-popovers-and-dialogs/)

## Focus Management

### Native Focus Behaviour (with `.showModal()`)

1. When opened: focus moves to the first focusable element inside the dialog
2. Tab/Shift+Tab cycles through focusable elements within the dialog only
3. Users CANNOT tab to page content behind the dialog
4. Users CAN tab to browser chrome (address bar, etc.) -- this is intentional and correct
5. When closed: focus returns to the element that triggered the dialog

The W3C APA Working Group confirmed: the native dialog element's behaviour is correct. You should NOT prevent users from tabbing to browser UI. "Focus trapping" means preventing access to page content behind the dialog, not imprisoning users in the dialog forever.

**Source:** [CSS-Tricks -- No Need to Trap Focus on Dialog](https://css-tricks.com/there-is-no-need-to-trap-focus-on-a-dialog-element/)

### The `autofocus` Attribute

- Place `autofocus` on the element the user is most likely to interact with first
- For confirmation dialogs: place `autofocus` on the Cancel/safe button, NOT the destructive action -- prevents accidental confirmations
- If no element has `autofocus`, focus goes to the first focusable element
- Avoid placing `autofocus` on the `<dialog>` element itself (inconsistent browser behaviour)
- If `autofocus` targets an element at the bottom of the dialog DOM, the modal opens scrolled down, forcing users to scroll back up -- consider dialog structure carefully

```html
<dialog>
  <h2>Delete account?</h2>
  <p>This cannot be undone.</p>
  <form method="dialog">
    <button autofocus value="cancel">Cancel</button>
    <button value="delete">Delete account</button>
  </form>
</dialog>
```

**Source:** [Jared Cunha -- Dialog Accessibility and UX](https://jaredcunha.com/blog/html-dialog-getting-accessibility-and-ux-right)

## Accessibility

### Built-in Accessibility of `<dialog>`

- Default role: `dialog`
- Alternative role: `alertdialog` (for urgent confirmations requiring immediate response)
- Modal dialogs have implicit `aria-modal="true"`
- Escape key closes modal dialogs
- Screen readers announce the dialog when it opens

### Required Additions

- **`aria-labelledby`**: Point to the dialog's heading so screen readers announce the title
- **`aria-describedby`** (optional): Point to descriptive content for additional context
- **Explicit close button**: Always provide a visible close mechanism; do not rely solely on Escape
- Do NOT use `tabindex` on the `<dialog>` element itself -- it is not an interactive element

```html
<dialog aria-labelledby="dialog-title" aria-describedby="dialog-desc">
  <h2 id="dialog-title">Confirm deletion</h2>
  <p id="dialog-desc">
    This will permanently delete your account and all data.
  </p>
  <form method="dialog">
    <button autofocus value="cancel">Cancel</button>
    <button value="delete">Delete account</button>
  </form>
</dialog>
```

### `role="alertdialog"`

Use `alertdialog` instead of the default `dialog` role when the dialog demands immediate attention for critical alerts or destructive confirmations. Screen readers treat alert dialogs with higher urgency.

```html
<dialog role="alertdialog" aria-labelledby="alert-title" aria-describedby="alert-desc">
  <h2 id="alert-title">Unsaved changes</h2>
  <p id="alert-desc">You have unsaved changes that will be lost.</p>
  <form method="dialog">
    <button autofocus value="cancel">Keep editing</button>
    <button value="discard">Discard changes</button>
  </form>
</dialog>
```

### Keyboard Interaction

- `Escape`: closes the modal dialog
- `Tab`: moves forward through focusable elements inside dialog
- `Shift+Tab`: moves backward through focusable elements
- `Enter`: activates focused button/control

**Sources:** [MDN `<dialog>`](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/dialog), [Adrian Roselli -- Dialog Focus in Screen Readers](https://adrianroselli.com/2020/10/dialog-focus-in-screen-readers.html), [W3C APG -- Modal Dialog Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/)

## Backdrop Styling

The `::backdrop` pseudo-element is a full-viewport box rendered immediately behind any element in the top layer. It only appears when a dialog is opened with `.showModal()`.

**Key characteristics:**
- Does NOT inherit from any element (no cascade conflicts)
- Supports all box-model CSS properties
- Each top-layer element gets its own `::backdrop`

```css
/* Semi-transparent dark overlay */
dialog::backdrop {
  background: oklch(0% 0 0 / 0.5);
}

/* Blur effect */
dialog::backdrop {
  backdrop-filter: blur(4px);
  background: oklch(0% 0 0 / 0.25);
}
```

**Source:** [MDN ::backdrop](https://developer.mozilla.org/en-US/docs/Web/CSS/::backdrop), [Chrome Developers -- ::backdrop inheritance changes](https://developer.chrome.com/blog/css-backdrop-inheritance)

## Entry and Exit Animations

For the underlying CSS features (`@starting-style`, `transition-behavior: allow-discrete`, animating `display`), see `01-fundamentals.md`. Below is the dialog-specific pattern combining all four:

### Complete Entry + Exit Animation Pattern

```css
/* Open state */
dialog[open] {
  opacity: 1;
  transform: translateY(0);
}

/* Closed state (what it animates TO on exit) */
dialog {
  opacity: 0;
  transform: translateY(-1rem);

  transition:
    opacity 0.3s ease,
    transform 0.3s ease,
    overlay 0.3s ease allow-discrete,
    display 0.3s ease allow-discrete;
}

/* Entry state (what it animates FROM on entry) */
@starting-style {
  dialog[open] {
    opacity: 0;
    transform: translateY(1rem);
  }
}

/* Backdrop animation */
dialog::backdrop {
  background: oklch(0% 0 0 / 0);

  transition:
    background 0.3s ease,
    overlay 0.3s ease allow-discrete,
    display 0.3s ease allow-discrete;
}

dialog[open]::backdrop {
  background: oklch(0% 0 0 / 0.5);
}

@starting-style {
  dialog[open]::backdrop {
    background: oklch(0% 0 0 / 0);
  }
}
```

### Respect Reduced Motion

```css
@media (prefers-reduced-motion: reduce) {
  dialog,
  dialog::backdrop {
    transition-duration: 0.01ms;
  }
}
```

**Sources:** [Chrome Developers -- Four New CSS Features for Entry/Exit Animations](https://developer.chrome.com/blog/entry-exit-animations/), [web.dev -- Baseline Entry Animations](https://web.dev/blog/baseline-entry-animations), [Frontend Masters -- Dialog with Entry and Exit Animations](https://frontendmasters.com/blog/the-dialog-element-with-entry-and-exit-animations/)

## The `closedby` Attribute

The `closedby` attribute (Chrome 134+, March 2025) provides declarative control over how dialogs can be dismissed:

| Value | Escape key | Click outside | Close button (JS) |
|---|---|---|---|
| `"none"` | No | No | Yes |
| `"closerequest"` | Yes | No | Yes |
| `"any"` | Yes | Yes | Yes |

**Defaults:** Modal dialogs default to `"closerequest"`. Non-modal dialogs default to `"none"`.

```html
<!-- Light dismiss enabled for modal -->
<dialog closedby="any">
  <p>Click outside or press Escape to close.</p>
  <button onclick="this.closest('dialog').close()">Close</button>
</dialog>
```

### Manual Light Dismiss (Polyfill for Browsers Without `closedby`)

```javascript
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) {
    dialog.close("dismiss");
  }
});
```

This works because clicking the `::backdrop` fires a click event on the dialog itself where `event.target === dialog`. Clicking content inside the dialog has a different target due to event bubbling.

**Sources:** [MDN HTMLDialogElement.closedBy](https://developer.mozilla.org/en-US/docs/Web/API/HTMLDialogElement/closedBy), [ste.digital -- closedby and command invokers](https://ste.digital/blog/levelling-up-your-dialogs-with-closedby-and-command-invokers)

## When to Use Modals vs Inline Expansion vs New Page

### Use a Modal Dialog When

- Confirming irreversible/destructive actions
- Collecting essential information needed to proceed (and the amount is small)
- The task is self-contained and quick (rename, confirm, simple form)
- User-initiated and directly related to current task

### Use Inline Expansion When

- Content is supplementary and non-blocking
- The user should maintain context of the surrounding page
- Progressive disclosure of details within a list or form
- Editing a field in place

### Use a New Page When

- Content is lengthy or complex
- Users might want to bookmark or share the content
- The task involves multiple steps or heavy data entry
- Content needs its own URL for SEO or deep linking
- Mobile users (where modals are most problematic)

### The Five Ws Test

Ask before using an overlay:

1. **Who** -- Will it work across all devices and accessibility needs?
2. **What** -- How much content/interaction is required?
3. **When** -- Is the timing user-initiated or interruptive?
4. **Where** -- Will the entire overlay be visible?
5. **Why** -- Could this be a regular page instead?

**Sources:** [NN/g -- Modal vs Nonmodal](https://www.nngroup.com/articles/modal-nonmodal-dialog/), [NN/g -- Overuse of Overlays](https://www.nngroup.com/articles/overuse-of-overlays/)

## Confirmation Dialogs for Destructive Actions

### Structure

1. **Title**: State the action clearly ("Delete account?")
2. **Description**: Explain the consequences specifically ("This will permanently remove all your data. This action cannot be undone.")
3. **Buttons**: Use descriptive verb+noun labels, NOT "Yes/No" or "OK/Cancel"

### Button Design

- Place `autofocus` on the safe/cancel button
- Style the destructive button with a muted filled background (not a red outline which looks like a primary CTA)
- The cancel button should be more visually prominent or equally weighted

```css
/* Don't: red outline draws attention like a primary action */
.destructive-btn-bad {
  border: 1px solid oklch(55% 0.25 25);
  color: oklch(55% 0.25 25);
  background: oklch(100% 0 0);
}

/* Do: muted filled background, same hue */
.destructive-btn {
  background: oklch(95% 0.03 25);
  color: oklch(45% 0.2 25);
  border: none;
}
```

### Friction Levels

- **Light**: Simple confirmation with descriptive buttons
- **Moderate**: Warning colour treatment + consequence description
- **Heavy**: Require typing a confirmation word (e.g., "DELETE") before enabling the action button

### Prefer Undo Over Confirmation

For the full rationale and undo-toast pattern, see `07-buttons.md` (section "Prefer Undo Over Confirmation Dialogs"). Reserve confirmation dialogs ONLY for truly irreversible, high-cost, or batch operations.

```html
<dialog aria-labelledby="confirm-title" aria-describedby="confirm-desc">
  <form method="dialog">
    <h2 id="confirm-title">Delete account?</h2>
    <p id="confirm-desc">
      This will permanently remove your account and all associated data.
      This cannot be undone.
    </p>
    <menu>
      <button autofocus value="cancel">Keep account</button>
      <button value="delete" class="destructive">Delete account</button>
    </menu>
  </form>
</dialog>
```

**Sources:** [NN/g -- Confirmation Dialog](https://www.nngroup.com/articles/confirmation-dialog/), [UX Planet -- Confirmation Dialogs](https://uxplanet.org/confirmation-dialogs-how-to-design-dialogues-without-irritation-7b4cf2599956), [UX Movement -- Destructive Actions](https://uxmovement.com/buttons/how-to-design-destructive-actions-that-prevent-data-loss/)

## Dialog HTML Structure Pattern

Use a grid layout with header/article/footer for consistent, scrollable dialogs:

```html
<dialog aria-labelledby="dialog-title">
  <form method="dialog">
    <header>
      <h2 id="dialog-title">Dialog title</h2>
      <button aria-label="Close" value="close">
        <svg aria-hidden="true"><!-- close icon --></svg>
      </button>
    </header>
    <article>
      <!-- scrollable content -->
    </article>
    <footer>
      <menu>
        <button autofocus value="cancel">Cancel</button>
        <button value="confirm">Confirm</button>
      </menu>
    </footer>
  </form>
</dialog>
```

```css
dialog {
  max-inline-size: min(90vw, 32rem);
  border: 1px solid oklch(92% 0.005 0);
  border-radius: 0.5rem;
  padding: 0;
  box-shadow: 0 1rem 3rem oklch(0% 0 0 / 0.2);
}

dialog > form {
  display: grid;
  grid-template-rows: auto 1fr auto;
  max-block-size: min(80dvb, 100%);
}

dialog > form > header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1rem 1.5rem;
  border-block-end: 1px solid oklch(92% 0.005 0);
}

dialog > form > article {
  overflow-y: auto;
  overscroll-behavior-y: contain;
  padding: 1.5rem;
}

dialog > form > footer {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  padding: 1rem 1.5rem;
  border-block-start: 1px solid oklch(92% 0.005 0);
}
```

### Mobile Adaptation (Action Sheet)

```css
@media (max-width: 768px) {
  dialog {
    max-inline-size: 100vw;
    max-block-size: 80dvb;
    margin-block-end: 0;
    border-end-end-radius: 0;
    border-end-start-radius: 0;
  }
}
```

**Source:** [web.dev -- Building a Dialog Component](https://web.dev/articles/building/a-dialog-component)

## Scroll Lock

Prevent background scrolling when a modal is open:

```css
html:has(dialog[open]) {
  overflow: hidden;
}
```

Prevent scroll chaining from the dialog content to the page:

```css
dialog > form > article {
  overscroll-behavior-y: contain;
}
```

**Why this matters:**
- Background scrolling while a modal is open is disorienting
- Users lose their place on the page behind the dialog
- `overscroll-behavior: contain` prevents the page from scrolling when the user reaches the end of dialog content

## Common Mistakes

### Mistake 1: Overusing modals

Modals interrupt workflow and force context-switching. Users develop "modal blindness" -- they click through without reading. Newsletter signups and marketing interruptions cause "visceral disdain" (NN/g research). The more often modals appear, the less effective they become.

### Mistake 2: Nested modals

Opening a modal from within a modal confuses users and creates disorientation. Users lose track of where they are. Focus management becomes unreliable across stacked modals. Alternative: replace inner modal with inline expansion, a new page, or a step within the same dialog.

### Mistake 3: Poor mobile handling

Modals that work on desktop often fail on mobile (content overflows, controls off-screen). Screen magnifier users face the same problems. Touch targets may be too small or unreachable. Solution: convert modals to full-screen on mobile (action sheet pattern).

### Mistake 4: Missing close mechanisms

Users feel "trapped" without a clear exit. Always provide: visible close button, Escape key, and (for non-critical modals) backdrop click. The Back button should close the modal, not navigate browser history.

### Mistake 5: Vague button labels

"OK" / "Cancel" on confirmation dialogs leads to accidental actions. Use descriptive labels: "Delete account" / "Keep account". Button text: verb + noun, meaningful out of context.

### Mistake 6: No scroll lock

Background scrolling while a modal is open is disorienting. Always use `html:has(dialog[open]) { overflow: hidden; }` and `overscroll-behavior: contain` on the scrollable dialog content.

### Mistake 7: Auto-triggered modals

Do not show pop-ups right after a user enters a screen. Modals should be user-initiated or directly related to a critical system event. Auto-triggered marketing modals erode trust.

**Sources:** [NN/g -- Modal vs Nonmodal](https://www.nngroup.com/articles/modal-nonmodal-dialog/), [NN/g -- Overuse of Overlays](https://www.nngroup.com/articles/overuse-of-overlays/), [Fireart -- Nested Modals](https://fireart.studio/blog/learn-why-you-should-exclude-nested-models-from-your-design-and-how-to-replace-them/)

## Toast and Notification Patterns

Use the Popover API for toast notifications. Toasts are non-modal, non-blocking messages that appear temporarily and dismiss automatically.

```html
<div id="toast" popover="manual" role="status" aria-live="polite">
  Message deleted.
  <button onclick="undoDelete()">Undo</button>
</div>
```

```javascript
function showToast(message, duration = 5000) {
  const toast = document.getElementById("toast");
  toast.textContent = message;
  toast.showPopover();

  setTimeout(() => {
    toast.hidePopover();
  }, duration);
}
```

```css
#toast {
  position: fixed;
  inset-block-end: 1.5rem;
  inset-inline-start: 50%;
  translate: -50% 0;

  background: oklch(25% 0.02 0);
  color: oklch(100% 0 0);
  padding: 0.75rem 1.5rem;
  border-radius: 0.5rem;
  border: none;
  box-shadow: 0 0.5rem 1.5rem oklch(0% 0 0 / 0.3);
}
```

### Key Guidelines for Toasts

- Use `role="status"` and `aria-live="polite"` so screen readers announce the message without interrupting
- Use `popover="manual"` -- toasts should not light-dismiss on click outside
- Include an Undo action when the toast replaces a confirmation dialog
- Auto-dismiss after 5-10 seconds
- Position at the bottom of the viewport to avoid blocking content
- Do NOT use toasts for critical errors or actions requiring user response (use a dialog instead)

**Source:** [Frontend Masters -- Menus, Toasts and More with Popover API](https://frontendmasters.com/blog/menus-toasts-and-more/)

## Chapter Summary

1. Use `.showModal()` for modals and `.show()` for non-modals -- never toggle the `open` attribute directly
2. Use `<dialog>` for interactions requiring focus trapping; use Popover API for tooltips, menus, and toasts
3. Place `autofocus` on the safest action (Cancel), not the destructive one
4. Add `aria-labelledby` pointing to the dialog heading; use `role="alertdialog"` for critical alerts
5. Animate dialogs with `@starting-style` and `transition-behavior: allow-discrete`; always respect `prefers-reduced-motion`
6. Use `closedby="any"` for light dismiss; polyfill with click-on-backdrop detection for broader support
7. Prefer undo toasts over confirmation dialogs for reversible actions; reserve modals for truly irreversible tasks
8. Structure dialogs as grid with header/article/footer; make the article scrollable with `overscroll-behavior: contain`
9. Lock page scroll with `html:has(dialog[open]) { overflow: hidden; }`
10. Apply the Five Ws test before choosing an overlay -- most content works better as a new page or inline expansion
11. Use descriptive button labels (verb + noun) -- never "OK" / "Cancel" on destructive confirmations
12. Convert modals to full-screen action sheets on mobile; never nest modals within modals
