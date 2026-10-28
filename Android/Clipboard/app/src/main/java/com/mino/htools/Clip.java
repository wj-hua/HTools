package com.mino.htools;

final class Clip {
    final long id;
    final String content;
    final long updatedAt;

    Clip(long id, String content, long updatedAt) {
        this.id = id;
        this.content = content;
        this.updatedAt = updatedAt;
    }
}
