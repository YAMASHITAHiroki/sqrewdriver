RSpec.describe SQS::Enhanced::Client, aggregate_failures: true do
  let(:sqs) { Aws::SQS::Client.new(stub_responses: true) }
  let(:client) { SQS::Enhanced::Client.new(client: sqs) }
  let(:queue_url) { "http://dummy.example.com" }

  describe "#send_message_buffered" do
    it "add message to buffer" do
      client.send_message_buffered(queue_url: queue_url, message_body: {foo: "body"})
      buffer = client.instance_variable_get(:@send_message_buffer)

      expect(buffer[queue_url][0]).to eq({message_body: {foo: "body"}})
    end

    it "send message to SQS when need_flush (by message count)" do
      sent_queue_url = nil
      entries = nil
      sqs.stub_responses(:send_message_batch, -> (ctx) {
        sent_queue_url = ctx.params[:queue_url]
        entries = ctx.params[:entries]
        sqs.stub_data(:send_message_batch)
      })
      10.times do
        client.send_message_buffered(queue_url: queue_url, message_body: {foo: "body"})
      end
      Concurrent::Promises.zip_futures(*client.instance_variable_get(:@waiting_futures)).wait!
      buffer = client.instance_variable_get(:@send_message_buffer)

      expect(buffer[queue_url]).to be_empty
      expect(sent_queue_url).to eq(queue_url)
      body = Oj.dump({foo: "body"})
      expect(entries).to eq([
        {message_body: body, id: "0"},
        {message_body: body, id: "1"},
        {message_body: body, id: "2"},
        {message_body: body, id: "3"},
        {message_body: body, id: "4"},
        {message_body: body, id: "5"},
        {message_body: body, id: "6"},
        {message_body: body, id: "7"},
        {message_body: body, id: "8"},
        {message_body: body, id: "9"},
      ])
    end

    context "multi thread" do
      it "can send all messages" do
        entries = []
        sqs.stub_responses(:send_message_batch, -> (ctx) {
          entries.concat(ctx.params[:entries])
          sqs.stub_data(:send_message_batch)
        })
        pool = Concurrent::FixedThreadPool.new(32)
        100.times do
          pool.post do
            15.times do
              client.send_message_buffered(queue_url: queue_url, message_body: "body")
            end
          end
        end
        pool.shutdown && pool.wait_for_termination
        client.flush

        buffer = client.instance_variable_get(:@send_message_buffer)

        expect(buffer[queue_url]).to be_empty
        expect(entries.length).to eq(100 * 15)
      end
    end
  end
end
