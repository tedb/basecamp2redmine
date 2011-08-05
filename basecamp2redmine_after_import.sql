CREATE TABLE `projects_trackers_distinct` SELECT distinct * FROM `projects_trackers`;
TRUNCATE TABLE `projects_trackers`;
ALTER TABLE `projects_trackers` ADD UNIQUE KEY `projects_trackers_unique` (`project_id`,`tracker_id`);
INSERT INTO `projects_trackers` SELECT * FROM `projects_trackers_distinct`;
DROP TABLE `projects_trackers_distinct`
