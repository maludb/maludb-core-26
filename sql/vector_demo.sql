SET search_path TO maludb_core, public;
INSERT INTO malu$vector_demo(label, embedding) VALUES
    ('alpha', '[1,0,0,0,0,0,0,0]'),
    ('beta',  '[0,1,0,0,0,0,0,0]'),
    ('gamma', '[1,1,0,0,0,0,0,0]');
SELECT label,
       ROUND((embedding <=> '[1,0,0,0,0,0,0,0]')::numeric, 6) AS cosine_distance
FROM malu$vector_demo
ORDER BY embedding <=> '[1,0,0,0,0,0,0,0]', label;
