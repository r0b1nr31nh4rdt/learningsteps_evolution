-- Schema of the LearningSteps database (from database_setup.sql of the
-- original repository). Single source for the Kubernetes schema job
-- (deploy.sh --db-init) and the tests.
-- Every statement uses IF NOT EXISTS, so running it again does no harm.

CREATE TABLE IF NOT EXISTS entries (
    id VARCHAR PRIMARY KEY,
    data JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at);
CREATE INDEX IF NOT EXISTS idx_entries_data_gin ON entries USING GIN (data);
