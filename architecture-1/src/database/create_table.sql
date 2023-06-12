CREATE TABLE movies_shows (
    title_id VARCHAR(max),
    title_type VARCHAR(max),
    primary_title VARCHAR(max),
    original_title VARCHAR(max),
    is_adult BOOLEAN,
    start_year INTEGER,
    end_year INTEGER,
    runtime_minutes INTEGER,
    genres SUPER
);