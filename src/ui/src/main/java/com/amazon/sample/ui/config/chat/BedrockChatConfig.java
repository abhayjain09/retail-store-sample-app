package com.amazon.sample.ui.config.chat;

import lombok.extern.slf4j.Slf4j;
import org.springframework.ai.bedrock.converse.BedrockChatOptions;
import org.springframework.ai.bedrock.converse.BedrockProxyChatModel;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.regions.Region;

@Configuration
@Slf4j
@ConditionalOnBean(ChatProperties.class)
@ConditionalOnProperty(
  prefix = ChatProperties.PREFIX,
  name = "provider",
  havingValue = "bedrock"
)
public class BedrockChatConfig {

  @Bean
  public ChatClient chatClient(
    ChatProperties properties,
    BedrockChatProperties bedrockProperties
  ) {
    log.warn("Creating Amazon Bedrock chat client");

    var modelOptions = BedrockChatOptions.builder()
      .model(properties.getModel())
      .maxTokens(properties.getMaxTokens())
      .temperature(properties.getTemperature())
      .build();

    var chatModel = BedrockProxyChatModel.builder()
      .credentialsProvider(DefaultCredentialsProvider.create())
      .region(Region.of(bedrockProperties.getRegion()))
      .defaultOptions(modelOptions)
      .build();

    return ChatClient.create(chatModel);
  }
}

