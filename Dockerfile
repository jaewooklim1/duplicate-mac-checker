FROM ruby:3.2

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install

COPY . .

EXPOSE 4567

CMD ["ruby", "duplicate-mac-checker-v2.rb"]