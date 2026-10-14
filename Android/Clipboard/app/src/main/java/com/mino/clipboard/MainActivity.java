package com.mino.clipboard;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.database.sqlite.SQLiteException;
import android.os.Build;
import android.os.Bundle;
import android.graphics.Point;
import android.view.MotionEvent;
import android.view.HapticFeedbackConstants;
import android.view.LayoutInflater;
import android.view.DragEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.ListView;
import android.widget.PopupMenu;
import android.widget.TextView;
import android.widget.Toast;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public final class MainActivity extends Activity {
    private ClipStore store;
    private EditText search;
    private ListView list;
    private Long draggedId;
    private float dragY;
    private int scrollStep;
    private boolean orderChanged;
    private List<Clip> orderBeforeDrag;
    private final ClipAdapter adapter = new ClipAdapter();
    private final Runnable autoScroll = new Runnable() {
        @Override public void run() {
            if (draggedId == null || scrollStep == 0 || !list.canScrollVertically(Integer.signum(scrollStep))) return;
            list.scrollListBy(scrollStep);
            moveAt(dragY);
            list.postOnAnimation(this);
        }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        Ui.applyInsets(this);
        store = new ClipStore(this);
        search = findViewById(R.id.search);
        list = findViewById(R.id.list);
        list.setAdapter(adapter);
        list.setEmptyView(findViewById(R.id.empty));
        list.setOnDragListener(this::handleDrag);
        findViewById(R.id.cloud).setOnClickListener(view -> startActivity(new Intent(this, CloudActivity.class)));
        findViewById(R.id.add).setOnClickListener(view -> openEditor(-1));
        findViewById(R.id.clear_search).setOnClickListener(view -> search.setText(""));
        search.addTextChangedListener(Ui.onTextChanged(this::refresh));
    }

    @Override protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override protected void onDestroy() {
        list.removeCallbacks(autoScroll);
        store.close();
        super.onDestroy();
    }

    private void openEditor(long id) {
        startActivity(new Intent(this, EditorActivity.class).putExtra(EditorActivity.EXTRA_ID, id));
    }

    private void refresh() {
        if (draggedId != null) {
            list.cancelDragAndDrop();
            finishDrag(false);
        }
        String query = search.getText().toString();
        findViewById(R.id.clear_search).setVisibility(query.isEmpty() ? View.GONE : View.VISIBLE);
        try {
            adapter.clips = store.search(query);
            adapter.notifyDataSetChanged();
            ((TextView) findViewById(R.id.count)).setText(getString(R.string.clips_count, adapter.getCount()));
            int title = !query.isEmpty() ? R.string.no_results : R.string.empty_title;
            int message = !query.isEmpty() ? R.string.no_results_message : R.string.empty_message;
            ((TextView) findViewById(R.id.empty_title)).setText(title);
            ((TextView) findViewById(R.id.empty_message)).setText(message);
        } catch (SQLiteException exception) {
            toast(R.string.load_failed);
        }
    }

    private void copy(Clip clip) {
        try {
            ClipboardManager clipboard = getSystemService(ClipboardManager.class);
            clipboard.setPrimaryClip(ClipData.newPlainText(getString(R.string.app_name), clip.content));
            // Android 13+ supplies its own clipboard confirmation.
            if (Build.VERSION.SDK_INT < 33) toast(R.string.copied);
        } catch (RuntimeException exception) {
            toast(R.string.action_failed);
        }
    }

    private void showMenu(View anchor, Clip clip) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(0, 1, 0, R.string.edit);
        menu.getMenu().add(0, 2, 1, R.string.delete);
        int position = positionOf(clip.id);
        menu.getMenu().add(0, 3, 2, R.string.move_up).setEnabled(position > 0);
        menu.getMenu().add(0, 4, 3, R.string.move_down).setEnabled(position >= 0 && position < adapter.getCount() - 1);
        menu.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == 1) openEditor(clip.id);
            else if (item.getItemId() == 2) confirmDelete(clip);
            else {
                int from = positionOf(clip.id);
                int to = from + (item.getItemId() == 3 ? -1 : 1);
                if (from >= 0 && to >= 0 && to < adapter.getCount()) {
                    move(from, to);
                    saveOrder();
                    refresh();
                }
            }
            return true;
        });
        menu.show();
    }

    private boolean startDrag(View view, long id) {
        if (adapter.getCount() < 2) return false;
        orderBeforeDrag = new ArrayList<>(adapter.clips);
        draggedId = id;
        orderChanged = false;
        Point grab = (Point) view.getTag(R.id.drag_touch);
        View.DragShadowBuilder shadow = new View.DragShadowBuilder(view) {
            @Override public void onProvideShadowMetrics(Point size, Point touch) {
                super.onProvideShadowMetrics(size, touch);
                if (grab != null) {
                    touch.set(Math.max(0, Math.min(grab.x, size.x - 1)),
                            Math.max(0, Math.min(grab.y, size.y - 1)));
                }
            }
        };
        boolean started = view.startDragAndDrop(ClipData.newPlainText("clip", ""),
                shadow, draggedId, 0);
        if (started) adapter.notifyDataSetChanged();
        else finishDrag(false);
        return started;
    }

    private boolean handleDrag(View view, DragEvent event) {
        if (draggedId == null || !draggedId.equals(event.getLocalState())) return false;
        switch (event.getAction()) {
            case DragEvent.ACTION_DRAG_STARTED:
            case DragEvent.ACTION_DRAG_ENTERED:
                return true;
            case DragEvent.ACTION_DRAG_LOCATION:
                dragY = event.getY();
                moveAt(dragY);
                int edge = Math.min(list.getHeight() / 3, Math.round(64 * getResources().getDisplayMetrics().density));
                int speed = Math.round(8 * getResources().getDisplayMetrics().density);
                scrollStep = dragY < edge ? -speed : dragY > list.getHeight() - edge ? speed : 0;
                list.removeCallbacks(autoScroll);
                if (scrollStep != 0) list.postOnAnimation(autoScroll);
                return true;
            case DragEvent.ACTION_DRAG_EXITED:
                list.removeCallbacks(autoScroll);
                return true;
            case DragEvent.ACTION_DROP:
                moveAt(event.getY());
                int from = positionOf(draggedId);
                int to = list.pointToPosition((int) event.getX(), (int) event.getY());
                if (from >= 0 && to >= 0 && to < adapter.getCount() && from != to) {
                    move(from, to);
                    orderChanged = true;
                }
                boolean saved = !orderChanged || saveOrder();
                if (saved && orderChanged) list.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);
                finishDrag(saved);
                return saved;
            case DragEvent.ACTION_DRAG_ENDED:
                finishDrag(false);
                return true;
            default:
                return true;
        }
    }

    private void moveAt(float y) {
        if (draggedId == null) return;
        int from = positionOf(draggedId);
        if (from < 0) return;
        int to = from;
        // Cross a neighbouring card's centre before moving; this avoids back-and-forth jitter.
        for (int i = 0; i < list.getChildCount(); i++) {
            View child = list.getChildAt(i);
            int position = list.getFirstVisiblePosition() + i;
            float centre = (child.getTop() + child.getBottom()) / 2f;
            if (position < from && y < centre) to = Math.min(to, position);
            if (position > from && y > centre) to = Math.max(to, position);
        }
        if (from != to) {
            move(from, to);
            orderChanged = true;
        }
    }

    private void move(int from, int to) {
        int first = list.getFirstVisiblePosition();
        View firstView = list.getChildAt(0);
        int offset = firstView == null ? 0 : firstView.getTop() - list.getPaddingTop();
        adapter.clips.add(to, adapter.clips.remove(from));
        adapter.notifyDataSetChanged();
        list.setSelectionFromTop(first, offset);
    }

    private int positionOf(long id) {
        for (int i = 0; i < adapter.getCount(); i++) {
            if (adapter.getItemId(i) == id) return i;
        }
        return -1;
    }

    private boolean saveOrder() {
        List<Long> ids = new ArrayList<>();
        for (Clip clip : adapter.clips) ids.add(clip.id);
        try {
            if (store.reorder(ids)) return true;
        } catch (SQLiteException exception) {
            // A failed transaction leaves the previously saved order intact.
        }
        toast(R.string.order_failed);
        return false;
    }

    private void finishDrag(boolean saved) {
        if (draggedId == null) return;
        list.removeCallbacks(autoScroll);
        if (!saved && orderBeforeDrag != null) adapter.clips = orderBeforeDrag;
        draggedId = null;
        orderBeforeDrag = null;
        scrollStep = 0;
        orderChanged = false;
        adapter.notifyDataSetChanged();
    }

    private void confirmDelete(Clip clip) {
        new AlertDialog.Builder(this)
                .setTitle(R.string.delete_title)
                .setMessage(R.string.delete_message)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.delete, (dialog, which) -> {
                    try {
                        toast(store.delete(clip.id) ? R.string.deleted : R.string.missing_clip);
                        refresh();
                    } catch (SQLiteException exception) {
                        toast(R.string.action_failed);
                    }
                }).show();
    }

    private String formatDate(long millis) {
        var date = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault());
        LocalDate today = LocalDate.now();
        String time = date.format(DateTimeFormatter.ofPattern("HH:mm", Locale.CHINA));
        if (date.toLocalDate().equals(today)) return getString(R.string.today, time);
        if (date.toLocalDate().equals(today.minusDays(1))) return getString(R.string.yesterday, time);
        return date.format(DateTimeFormatter.ofPattern("yyyy/MM/dd", Locale.CHINA));
    }

    private void toast(int message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    private final class ClipAdapter extends BaseAdapter {
        private List<Clip> clips = new ArrayList<>();
        @Override public int getCount() { return clips.size(); }
        @Override public Clip getItem(int position) { return clips.get(position); }
        @Override public long getItemId(int position) { return getItem(position).id; }
        @Override public boolean hasStableIds() { return true; }

        @android.annotation.SuppressLint("ClickableViewAccessibility")
        @Override public View getView(int position, View convertView, ViewGroup parent) {
            View view = convertView != null ? convertView
                    : LayoutInflater.from(MainActivity.this).inflate(R.layout.item_clip, parent, false);
            Clip clip = getItem(position);
            view.setOnClickListener(card -> openEditor(clip.id));
            view.setOnLongClickListener(card -> startDrag(card, clip.id));
            // Observe the grab point only; returning false preserves native click/accessibility handling.
            view.setOnTouchListener((card, event) -> {
                if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                    card.setTag(R.id.drag_touch, new Point(Math.round(event.getX()), Math.round(event.getY())));
                }
                return false;
            });
            view.setAlpha(draggedId != null && draggedId == clip.id ? 0.35f : 1f);
            ((TextView) view.findViewById(R.id.clip_content)).setText(clip.content);
            ((TextView) view.findViewById(R.id.clip_meta)).setText(getString(R.string.metadata,
                    formatDate(clip.updatedAt), Ui.characterCount(clip.content)));
            view.findViewById(R.id.copy).setOnClickListener(button -> copy(clip));
            view.findViewById(R.id.more).setOnClickListener(button -> showMenu(button, clip));
            return view;
        }
    }
}
