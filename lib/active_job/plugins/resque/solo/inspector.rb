require_relative "lock"
require 'json'
require 'digest/sha1'

module ActiveJob
  module Plugins
    module Resque
      module Solo
        class Inspector
          REENQUEUE_DELAY = 1.second
          JOB_WRAPPER_CLASS = 'ActiveJob::QueueAdapters::ResqueAdapter::JobWrapperWithLock'.freeze

          def initialize(any_args, only_args, except_args, lock_key_prefix)
            @any_args = !!any_args
            @only_args = only_args
            @except_args = except_args || []
            # always ignore the ActiveJob symbol hash key.
            @except_args << "_aj_symbol_keys" unless @except_args.include?("_aj_symbol_keys")
            @lock_key_prefix = lock_key_prefix.present? ? lock_key_prefix : "ajr_solo"
          end

          def self.resque_present?
            ActiveJob::Base.queue_adapter.is_a? ActiveJob::QueueAdapters::ResqueAdapter
          end

          def self.resque_scheduler_present?
            defined? ::Resque::Scheduler
          end

          def around_enqueue(job, block)
            if Inspector.resque_present?

              Lock.try_acquire_release(lock_key('enqueued', job)) do |lock, extend_at|
                @lock = lock
                @extend_lock_at = extend_at

                if !job_enqueued?(job)
                  block.call
                end
              end
            else
              # if resque is not present, always enqueue
              block.call
            end
          end

          def job_enqueued?(job)
            size = ::Resque.size(job.queue_name) + scheduled_jobs_count
            return false if size.zero?

            enqueued_jobs = ::Resque.peek(job.queue_name, 0, 0) + scheduled_jobs(job.queue_name)

            extend_lock

            job_class, job_arguments = job(job)

            (enqueued_jobs.size-1).downto(0) do |i|
              scheduled_job = enqueued_jobs[i]
              return true if job_enqueued_with_args?(job_class, job_arguments, scheduled_job)
              extend_lock
            end

            false
          end

          def job_executing?(job)
            job_class, job_arguments = job(job)

            is_executing = ::Resque.workers.any? do |worker|
              processing = worker.processing
              next false if processing.blank?
              args = processing["payload"]["args"][0]
              job_with_args_eq?(job_class, job_arguments, args)
            end

            extend_lock unless is_executing

            is_executing
          end

          def job_enqueued_with_args?(job_class, job_arguments, scheduled_job)
            args = scheduled_job["args"][0]
            job_with_args_eq?(job_class, job_arguments, args)
          end

          def job_with_args_eq?(job_class, job_arguments, wrapper_args)
            return false if wrapper_args['job_class'] != job_class
            encoded_arguments = wrapper_args['arguments']
            encoded_arguments = job_args(encoded_arguments)
            encoded_arguments == job_arguments
          end

          def job(job)
            job_arguments = ActiveJob::Arguments.serialize(job.arguments)
            job_arguments = job_args(job_arguments)
            job_class = job.class.name
            [ job_class, job_arguments ]
          end

          def job_args(args)
            if args.present?
              if @any_args
                args = []
              else
                args.map do |arg|
                  if arg.is_a? Hash
                    arg.keep_if { |k,v| @only_args.include?(k.to_s) } if @only_args.present?
                    arg.keep_if { |k,v| !@except_args.include?(k.to_s) } if @except_args.present?
                  end

                  arg
                end
              end
            end

            args
          end

          def scheduled_jobs(queue_name)
            return [] unless Inspector.resque_scheduler_present?

            ::Resque.find_delayed_selection(JOB_WRAPPER_CLASS) do |job|
              job[0]['queue_name'] == queue_name ? job : nil
            end.map { |j| JSON.parse(j) }
          end

          def scheduled_jobs_count
            return 0 unless Inspector.resque_scheduler_present?

            ::Resque.count_all_scheduled_jobs
          end

          def lock_key(type, job)
            job_class, job_arguments = job(job)
            sha1 = Digest::SHA1.hexdigest(job_arguments.to_json)
            "#{@lock_key_prefix}:#{type}:#{job_class}:#{sha1}"
          end

          def extend_lock
            if Time.now.utc >= @extend_lock_at
              @extend_lock_at = @lock.extend
            end
          end
        end
      end
    end
  end
end
