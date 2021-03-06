###
# loads and featurizes data
###
source("1-dependencies.R")


process_data <- function(dat, is_training_data){
    # process data into form where id is primary key, extracting features:
    # first event id, last event id, frequency counts of ids
    
    if (is_training_data) {
    responses <- dat %>% group_by(id) %>% 
                         summarise(last_timestamp = last(timestamp), 
                                   response=last(event)) %>% 
                         mutate(response = as.factor(response))
    
    assert_that(all(table(dat$timestamp) == 1))  # getting response rows like this depends on timestamps being unique
    row_is_response <- (dat$timestamp %in% responses$last_timestamp)
    responses <- select(responses, -last_timestamp)
    dat <- dat %>% filter(!row_is_response)
    }
    
    # get first event, last event (response), and count of events
    critical_events <- dat %>% group_by(id) %>% 
        summarise(last_event = last(event),
                  penultimate_event = nth(event, n=-2),
                  first_event = first(event),
                  count_events = n()) %>% 
        mutate(last_event = as.factor(last_event),
               penultimate_event = as.factor(penultimate_event),
               first_event = as.factor(first_event))
    
    # get frequency counts
    count_events <- dat %>% 
        group_by(id, event) %>% 
        summarise(n = n()) %>% 
        spread(event, n)
    count_events[is.na(count_events)] <- 0
    names(count_events) <- make.names(names(count_events))
    
    if (is_training_data) {
    # if we're making training data, join responses back in
        count_events <- left_join(count_events, responses, by='id')
    }
    
    return(left_join(critical_events, count_events))
}


augment_data <- function(dat, train, n_iter){
    # generates more training data by recalculating features
    # on ids with n occured events by removing the nth observation 
    # and setting event[n-1] as response. 
    # iteratively "shaves" dataset down from max n_events to ids with only 2 events
    
    out <- train[0,]  # create empty dataframe with same schema as train
    valid_ids <- train %>%   # a valid id is one with count_events > 2
        filter((count_events > 2)) 
    iter = 0
    
    # shave until n_iter is reached
    while (max(valid_ids$count_events) > 2 & iter < n_iter){
        dat <- filter(dat, id %in% valid_ids$id)
        
        last_events_to_remove <- dat %>% group_by(id) %>% summarise(last_timestamp = last(timestamp))
        dat <- filter(dat, !(timestamp %in% last_events_to_remove$last_timestamp))
        
        valid_ids <- process_data(dat, is_training_data = TRUE)
        out <- out %>% bind_rows(valid_ids)
        
        message("Shaving event number: ", iter + 1)
        iter = iter + 1
    }
    
    return(out)
}


# MAIN
# To create training and testing dataset
# 1. extract all ids from 'train' that are in 'test' and convert to training data
# 2. get last event from leftover ids, remove those rows, and use the event as response
# 2.1. as next step, generate more training data by moving backwards another event in time

train_raw <- read.csv("data/train.csv")
test_raw <- read.csv("data/test.csv")
subm <- read.csv("data/sample_submission.csv")

# move features from the training set to test set now
test_raw <- test_raw %>% left_join(filter(train_raw, id %in% test_raw$id))
train_raw <- filter(train_raw, !(id %in% test_raw$id)) %>% mutate(id = as.character(id))
assert_that(all(!train_raw$id %in% test_raw$id))  # assert no overlap between training and test sets

# feature engineering
test <- process_data(test_raw, is_training_data = FALSE)
train <- process_data(train_raw, is_training_data = TRUE)

# data augmentation
# note: do we want to consider adding test data into this? think about leakage...
# train <- train %>% bind_rows(augment_data(dat=train_raw, train, n_iter = 1))


# this is a temporary fix for NAs coming out of load_process_data.augment_data()
train[is.na(train)] <- 0 
correct_sum_event_counts <- all(apply(select(train, X30018:X45003), 1, sum) == train$count_events)
assert_that(correct_sum_event_counts) # assert that row sums check out

train_matrix <- sparse.model.matrix(response ~ ., data=select(train, -id))
response <- as.integer(as.factor(train$response)) - 1